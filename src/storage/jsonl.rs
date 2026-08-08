//! One session, one file, one line per mutation.
//!
//! The only failure a crash can produce is a **torn last line**: the process
//! died mid-write. That is recoverable — truncate back to the last complete
//! line and carry on appending. A malformed line anywhere *else* is not
//! something a crash can do, so it is corruption and we refuse to open.
//!
//! Every append is flushed. An agent that reports work it did not persist is
//! worse than an agent that is slow.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::records::{FORMAT_VERSION, Header, Line};
use crate::storage::{Result, Storage, StorageError};

#[derive(Debug)]
pub struct Sink {
    file: File,
    path: PathBuf,
}

impl Sink {
    pub fn append(&mut self, line: &Line) -> Result<()> {
        let mut text = serde_json::to_string(line).expect("a session line must serialise");
        text.push('\n');
        self.file.write_all(text.as_bytes())?;
        self.file.flush()?;
        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Storage {
    /// Create or reopen a JSONL-backed session.
    ///
    /// Reopening replays the file: entries, records, lane leaves, facts, and
    /// the high-water `seq` all come back, and appends resume after the last
    /// intact line.
    pub fn open(
        path: impl AsRef<Path>,
        id: impl Into<String>,
        cwd: Option<String>,
    ) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let (lines, valid_len) = read_lines(&path)?;
        let existed = !lines.is_empty();

        // Drop a torn tail before we append anything after it.
        if valid_len < file_len(&path)? {
            let file = OpenOptions::new().write(true).open(&path)?;
            file.set_len(valid_len)?;
            file.sync_all()?;
        }

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(&path)?;
        file.seek(SeekFrom::End(0))?;
        let sink = Sink { file, path };

        let header = lines
            .iter()
            .find_map(|line| match line {
                Line::Header(header) => Some(header.clone()),
                _ => None,
            })
            .unwrap_or_else(|| Header::new(id, cwd));
        if header.version != FORMAT_VERSION {
            return Err(StorageError::Version(header.version, FORMAT_VERSION));
        }

        let mut storage = Storage::with_sink(header.clone(), sink);
        if existed {
            for line in lines {
                storage.replay_line(line);
            }
        } else {
            storage.write_header()?;
        }
        Ok(storage)
    }
}

fn file_len(path: &Path) -> Result<u64> {
    match std::fs::metadata(path) {
        Ok(meta) => Ok(meta.len()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(e.into()),
    }
}

/// Parse every line, returning the parsed lines and the byte length of the
/// intact prefix.
fn read_lines(path: &Path) -> Result<(Vec<Line>, u64)> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Vec::new(), 0)),
        Err(e) => return Err(e.into()),
    };

    let mut parsed = Vec::new();
    let mut valid_len: u64 = 0;
    let mut reader = BufReader::new(file);
    let mut raw = Vec::new();
    let mut number = 0usize;

    loop {
        raw.clear();
        let read = reader.read_until(b'\n', &mut raw)?;
        if read == 0 {
            break;
        }
        number += 1;
        let complete = raw.last() == Some(&b'\n');
        let text = String::from_utf8_lossy(&raw);
        let trimmed = text.trim_end_matches(['\n', '\r']);

        if trimmed.is_empty() {
            if complete {
                valid_len += read as u64;
            }
            continue;
        }

        match serde_json::from_str::<Line>(trimmed) {
            Ok(line) => {
                parsed.push(line);
                if complete {
                    valid_len += read as u64;
                } else {
                    // Parsed, but no trailing newline: the write was cut off at
                    // exactly a record boundary. Keep the data, drop the bytes,
                    // and let the next append start on a clean line.
                    parsed.pop();
                }
            }
            Err(source) => {
                // Only the final line may be torn.
                let at_eof = reader.fill_buf()?.is_empty();
                if at_eof {
                    break;
                }
                return Err(StorageError::Corrupt {
                    line: number,
                    source,
                });
            }
        }
    }
    Ok((parsed, valid_len))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::{Entry, MAIN_LANE, Record};
    use crate::storage::Order;
    use serde_json::json;

    fn user(text: &str) -> Entry {
        Entry::message(MAIN_LANE, json!({"role": "user", "content": text}))
    }

    fn temp() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.jsonl");
        (dir, path)
    }

    #[test]
    fn a_reopened_session_is_the_session_it_was() {
        let (_dir, path) = temp();
        let (a, b, seq) = {
            let mut s = Storage::open(&path, "s1", Some("workspace".into())).unwrap();
            let a = s.append_entry(user("one")).unwrap();
            s.append_record(Record::new(MAIN_LANE, "operation_started", json!({})))
                .unwrap();
            let b = s.append_entry(user("two")).unwrap();
            s.set_fact("label", json!("checkpoint")).unwrap();
            (a, b, s.seq())
        };

        let s = Storage::open(&path, "s1", None).unwrap();
        assert_eq!(s.seq(), seq, "the counter resumes, it does not restart");
        assert_eq!(s.leaf(MAIN_LANE), Some(b.clone()));
        assert_eq!(s.fact("label").unwrap(), "checkpoint");
        let path_ids: Vec<_> = s
            .path_entries(MAIN_LANE)
            .iter()
            .map(|e| e.id.clone())
            .collect();
        assert_eq!(path_ids, vec![a, b]);
        assert_eq!(s.header().version, FORMAT_VERSION);
    }

    #[test]
    fn a_torn_tail_is_truncated_and_the_prefix_survives() {
        let (_dir, path) = temp();
        let a = {
            let mut s = Storage::open(&path, "s1", None).unwrap();
            s.append_entry(user("one")).unwrap()
        };

        // Simulate dying mid-write.
        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(br#"{"kind":"entry","id":"e_torn","la"#)
            .unwrap();
        f.flush().unwrap();

        let mut s = Storage::open(&path, "s1", None).unwrap();
        assert_eq!(
            s.find_entries(None, Order::OldestFirst).len(),
            1,
            "torn line dropped"
        );
        assert_eq!(s.leaf(MAIN_LANE), Some(a.clone()));

        // Appends resume cleanly, and the file stays valid JSON throughout.
        let b = s.append_entry(user("two")).unwrap();
        drop(s);
        let text = std::fs::read_to_string(&path).unwrap();
        for line in text.lines().filter(|l| !l.trim().is_empty()) {
            serde_json::from_str::<Line>(line).expect("every line parses");
        }
        let s = Storage::open(&path, "s1", None).unwrap();
        assert_eq!(s.leaf(MAIN_LANE), Some(b));
    }

    #[test]
    fn a_malformed_line_in_the_middle_is_corruption() {
        let (_dir, path) = temp();
        {
            let mut s = Storage::open(&path, "s1", None).unwrap();
            s.append_entry(user("one")).unwrap();
            s.append_entry(user("two")).unwrap();
        }
        // Damage a line that is not the last one.
        let text = std::fs::read_to_string(&path).unwrap();
        let mut lines: Vec<&str> = text.lines().collect();
        lines[1] = "{not json at all";
        std::fs::write(&path, format!("{}\n", lines.join("\n"))).unwrap();

        let err = Storage::open(&path, "s1", None).unwrap_err();
        assert!(matches!(err, StorageError::Corrupt { .. }), "got {err}");
    }

    #[test]
    fn a_future_format_version_is_refused_rather_than_guessed_at() {
        let (_dir, path) = temp();
        std::fs::write(
            &path,
            "{\"kind\":\"header\",\"version\":99,\"id\":\"s1\"}\n",
        )
        .unwrap();
        let err = Storage::open(&path, "s1", None).unwrap_err();
        assert!(matches!(err, StorageError::Version(99, 4)), "got {err}");
    }

    #[test]
    fn memory_and_jsonl_agree() {
        let (_dir, path) = temp();
        let mut disk = Storage::open(&path, "s1", None).unwrap();
        let mut mem = Storage::memory("s1");
        for backend in [&mut disk, &mut mem] {
            backend.append_entry(user("one")).unwrap();
            backend
                .append_record(Record::new(MAIN_LANE, "task_attempt", json!({})))
                .unwrap();
            backend.append_entry(user("two")).unwrap();
            backend.set_fact("name", json!("parity")).unwrap();
        }
        assert_eq!(disk.seq(), mem.seq());
        assert_eq!(
            disk.find_entries(None, Order::OldestFirst).len(),
            mem.find_entries(None, Order::OldestFirst).len()
        );
        assert_eq!(disk.find_records(None).len(), mem.find_records(None).len());
        assert_eq!(disk.fact("name"), mem.fact("name"));
    }
}
