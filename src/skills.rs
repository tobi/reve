//! Workspace skill discovery and frontmatter validation.

use serde::Serialize;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SkillError {
    #[error("{path}: {message}")]
    Invalid { path: PathBuf, message: String },
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub path: PathBuf,
    pub body: String,
}

pub fn discover(root: &Path) -> Result<Vec<Skill>, SkillError> {
    let mut files = Vec::new();
    collect(&root.join("skills"), &mut files)?;
    files.sort();
    let mut out = Vec::new();
    for path in files {
        let text = std::fs::read_to_string(&path)?;
        let (head, body) = parse(&text, &path)?;
        out.push(Skill {
            name: head.0,
            description: head.1,
            path,
            body,
        });
    }
    Ok(out)
}
fn collect(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), SkillError> {
    if !dir.is_dir() {
        return Ok(());
    }
    for e in std::fs::read_dir(dir)? {
        let p = e?.path();
        if p.is_dir() {
            collect(&p, out)?;
        } else if p.file_name().is_some_and(|n| n == "SKILL.md") {
            out.push(p);
        }
    }
    Ok(())
}
fn parse(text: &str, path: &Path) -> Result<((String, String), String), SkillError> {
    let mut lines = text.lines();
    if lines.next() != Some("---") {
        return Err(SkillError::Invalid {
            path: path.into(),
            message: "missing frontmatter".into(),
        });
    }
    let mut name = None;
    let mut desc = None;
    let mut body = Vec::new();
    let mut closed = false;
    for line in lines {
        if !closed && line == "---" {
            closed = true;
            continue;
        }
        if !closed {
            if let Some(v) = line.strip_prefix("name:") {
                name = Some(v.trim().to_string());
            } else if let Some(v) = line.strip_prefix("description:") {
                desc = Some(v.trim().to_string());
            }
        } else {
            body.push(line);
        }
    }
    let name = name
        .filter(|n| !n.is_empty())
        .ok_or_else(|| SkillError::Invalid {
            path: path.into(),
            message: "missing name".into(),
        })?;
    let description = desc
        .filter(|d| !d.is_empty())
        .ok_or_else(|| SkillError::Invalid {
            path: path.into(),
            message: "missing description".into(),
        })?;
    if !name
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
    {
        return Err(SkillError::Invalid {
            path: path.into(),
            message: "name must be lowercase ascii".into(),
        });
    }
    Ok(((name, description), body.join("\n")))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovers_and_validates_skills() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("skills/review/SKILL.md");
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(
            &p,
            "---\nname: review\ndescription: review changes\n---\nRead the diff.",
        )
        .unwrap();
        let found = discover(d.path()).unwrap();
        assert_eq!(found[0].name, "review");
        assert!(found[0].body.contains("Read"));
    }
    #[test]
    fn rejects_missing_frontmatter() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("skills/x/SKILL.md");
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, "# nope").unwrap();
        assert!(discover(d.path()).is_err());
    }
}
