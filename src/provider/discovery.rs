//! Asking an upstream what it serves.
//!
//! `models.yml` names the models an agent is *configured* for. That is a
//! deliberately short list — the default model and whatever else you have
//! chosen — and it is what the agent runs. But an OpenAI-compatible endpoint
//! also publishes its whole catalogue at `GET {baseUrl}/models`, and typing a
//! model id from memory is how you learn twenty minutes later that the slug was
//! `x-ai/grok-4.6` and not `xai/grok-4.6`.
//!
//! So discovery is a completion aid, never a source of truth:
//!
//! - It runs **after** startup, in the background. Nothing waits on it and no
//!   failure it can produce is fatal. An agent with no network still starts and
//!   still runs its configured model.
//! - It only probes providers whose API key is actually present. A provider
//!   whose `$ENV_VAR` is unset is not configured on this machine, and sending it
//!   an unauthenticated request would just be a 401 in someone's proxy log.
//! - It is cached on disk with a TTL, so launching the agent is not a request to
//!   every upstream you have ever configured.
//! - It never rewrites `models.yml`. The file is yours.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::config::{Api, Models};

/// How long a catalogue is considered current. Model lists change on the order
/// of weeks; a day is short enough to notice a new release and long enough that
/// normal use makes no requests at all.
pub const TTL: Duration = Duration::from_secs(24 * 60 * 60);

const TIMEOUT: Duration = Duration::from_secs(10);

/// One model an upstream says it serves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Discovered {
    /// `provider/id`, ready to paste into `agent.lua` or `/model`.
    pub reference: String,
    /// Context window, when the endpoint bothers to say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u32>,
    /// Whether the endpoint advertises reasoning support.
    #[serde(default)]
    pub reasoning: bool,
}

/// What was found, and when. Written next to the agent's own state.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Catalogue {
    /// Unix seconds. Compared against [`TTL`], not trusted for anything else.
    #[serde(default)]
    pub fetched_at: u64,
    #[serde(default)]
    pub models: Vec<Discovered>,
    /// Why a provider produced nothing, kept so `/models` can say so instead of
    /// silently listing less than you expected.
    #[serde(default)]
    pub failures: BTreeMap<String, String>,
}

impl Catalogue {
    pub fn is_fresh(&self) -> bool {
        now().saturating_sub(self.fetched_at) < TTL.as_secs()
    }

    pub fn read(path: &Path) -> Option<Self> {
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    /// Best effort: a cache we could not write is not worth a diagnostic, it
    /// just means the next launch asks again.
    pub fn write(&self, path: &Path) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(text) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(path, text);
        }
    }
}

pub fn cache_path(agent_root: &Path) -> PathBuf {
    agent_root.join(".reve").join("model-catalogue.json")
}

/// The cached catalogue if it is fresh, otherwise a new fetch (which is then
/// cached). Errors are carried inside [`Catalogue::failures`]; this function
/// does not fail.
pub async fn catalogue(agent_root: &Path, models: &Models) -> Catalogue {
    let path = cache_path(agent_root);
    if let Some(cached) = Catalogue::read(&path)
        && cached.is_fresh()
    {
        return cached;
    }
    let fresh = fetch(models, &|var| std::env::var(var).ok()).await;
    fresh.write(&path);
    fresh
}

/// Probe every provider that has a key, concurrently.
pub async fn fetch(models: &Models, lookup: &(dyn Fn(&str) -> Option<String> + Sync)) -> Catalogue {
    let client = match reqwest::Client::builder().timeout(TIMEOUT).build() {
        Ok(client) => client,
        Err(error) => {
            return Catalogue {
                fetched_at: now(),
                failures: BTreeMap::from([("*".to_string(), error.to_string())]),
                ..Default::default()
            };
        }
    };

    let probes = models.providers.iter().filter_map(|(name, provider)| {
        // Anthropic's list endpoint is a different shape and its catalogue is
        // small enough to type; `fake` never touches the network.
        if !matches!(provider.api, Api::OpenaiResponses | Api::OpenaiCompletions) {
            return None;
        }
        // "Has this upstream been given a key on this machine?" A provider
        // configured for a key that is not set is not configured here at all.
        let key = match provider.api_key.as_deref() {
            Some(reference) => match resolve(reference, lookup) {
                Some(key) if !key.is_empty() => Some(key),
                // Unset. Not an error and not worth reporting: this provider is
                // simply not in use on this machine.
                _ => return None,
            },
            None => None,
        };
        let base = resolve(&provider.base_url, lookup)?;
        Some((name.clone(), base, key, client.clone()))
    });

    let results = futures::future::join_all(probes.map(|(name, base, key, client)| async move {
        let outcome = probe(&client, &base, key.as_deref(), &name).await;
        (name, outcome)
    }))
    .await;

    let mut catalogue = Catalogue {
        fetched_at: now(),
        ..Default::default()
    };
    for (name, outcome) in results {
        match outcome {
            Ok(found) => catalogue.models.extend(found),
            Err(error) => {
                catalogue.failures.insert(name, error);
            }
        }
    }
    catalogue
        .models
        .sort_by(|a, b| a.reference.cmp(&b.reference));
    catalogue.models.dedup_by(|a, b| a.reference == b.reference);
    catalogue
}

async fn probe(
    client: &reqwest::Client,
    base_url: &str,
    api_key: Option<&str>,
    provider: &str,
) -> Result<Vec<Discovered>, String> {
    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let mut request = client.get(&url);
    if let Some(key) = api_key {
        request = request.bearer_auth(key);
    }
    let response = request.send().await.map_err(|e| e.to_string())?;
    let status = response.status();
    let body = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        // The first line only: an HTML error page from a proxy is not a useful
        // diagnostic at 400 characters.
        let hint = body.lines().next().unwrap_or_default();
        return Err(format!("HTTP {}: {}", status.as_u16(), truncate(hint, 120)));
    }
    let value: Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    Ok(parse(&value, provider))
}

/// The OpenAI list shape, plus the fields OpenRouter adds on top of it.
pub fn parse(value: &Value, provider: &str) -> Vec<Discovered> {
    let Some(rows) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|row| {
            let id = row.get("id").and_then(Value::as_str)?;
            // OpenRouter marks variants it is deprecating with a leading `~`.
            if id.starts_with('~') {
                return None;
            }
            let context_window = row
                .get("context_length")
                .or_else(|| row.get("context_window"))
                .and_then(Value::as_u64)
                .map(|n| n.min(u32::MAX as u64) as u32);
            let reasoning = row
                .get("supported_parameters")
                .and_then(Value::as_array)
                .is_some_and(|p| {
                    p.iter()
                        .filter_map(Value::as_str)
                        .any(|p| p == "reasoning" || p == "reasoning_effort")
                });
            Some(Discovered {
                reference: format!("{provider}/{id}"),
                context_window,
                reasoning,
            })
        })
        .collect()
}

fn resolve(value: &str, lookup: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    match value.strip_prefix('$') {
        Some(var) => lookup(var),
        None => Some(value.to_string()),
    }
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    text.chars().take(max).collect::<String>() + "…"
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn models_yml() -> Models {
        Models::parse(
            r#"
providers:
  openrouter:
    baseUrl: https://openrouter.ai/api/v1
    api: openai-responses
    apiKey: $OPENROUTER_API_KEY
    models:
      - id: x-ai/grok-4.6
  openai:
    baseUrl: https://api.openai.com/v1
    api: openai-responses
    apiKey: $OPENAI_API_KEY
    models:
      - id: gpt-5.6-luna
  anthropic:
    baseUrl: https://api.anthropic.com
    api: anthropic-messages
    apiKey: $ANTHROPIC_API_KEY
    models:
      - id: claude-opus-5
"#,
            "models.yml",
        )
        .unwrap()
    }

    #[test]
    fn the_openrouter_shape_yields_a_pasteable_reference() {
        // The real response, trimmed. `x-ai/grok-4.6` contains a slash, which
        // is exactly the id you would have got wrong by hand.
        let body = json!({"data": [
            {"id": "x-ai/grok-4.6", "context_length": 500000,
             "supported_parameters": ["reasoning", "tools"]},
            {"id": "openai/gpt-5.6", "context_length": 400000,
             "supported_parameters": ["tools"]},
        ]});
        let found = parse(&body, "openrouter");
        assert_eq!(
            found,
            vec![
                Discovered {
                    reference: "openrouter/x-ai/grok-4.6".into(),
                    context_window: Some(500_000),
                    reasoning: true,
                },
                Discovered {
                    reference: "openrouter/openai/gpt-5.6".into(),
                    context_window: Some(400_000),
                    reasoning: false,
                },
            ]
        );
    }

    #[test]
    fn a_deprecated_alias_is_not_offered() {
        let body = json!({"data": [{"id": "~x-ai/grok-latest"}, {"id": "x-ai/grok-4.6"}]});
        let found = parse(&body, "openrouter");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].reference, "openrouter/x-ai/grok-4.6");
    }

    #[test]
    fn a_bare_openai_list_needs_no_extra_fields() {
        let body = json!({"data": [{"id": "gpt-5.6-luna", "object": "model"}]});
        assert_eq!(
            parse(&body, "openai"),
            vec![Discovered {
                reference: "openai/gpt-5.6-luna".into(),
                context_window: None,
                reasoning: false,
            }]
        );
    }

    #[test]
    fn a_response_that_is_not_a_list_yields_nothing_rather_than_failing() {
        assert!(parse(&json!({"error": "nope"}), "openai").is_empty());
    }

    #[tokio::test]
    async fn only_upstreams_that_have_a_key_are_probed() {
        // No key anywhere: nothing is contacted, so this makes no requests and
        // cannot fail. The point is that an unset $ENV_VAR is not an error --
        // that provider is just not configured on this machine.
        let catalogue = fetch(&models_yml(), &|_| None).await;
        assert!(catalogue.models.is_empty());
        assert!(
            catalogue.failures.is_empty(),
            "an unset key is not a failure: {:?}",
            catalogue.failures
        );
        assert!(catalogue.is_fresh());
    }

    #[tokio::test]
    async fn an_unreachable_upstream_is_recorded_not_fatal() {
        // A key is present, so this provider *is* configured -- and the address
        // is reserved as unroutable, so the probe fails. Discovery must still
        // return, with the reason kept for `/models` to show.
        let models = Models::parse(
            r#"
providers:
  local:
    baseUrl: http://127.0.0.1:1
    api: openai-completions
    apiKey: $LOCAL_KEY
    models:
      - id: whatever
"#,
            "models.yml",
        )
        .unwrap();
        let catalogue = fetch(&models, &|_| Some("k".into())).await;
        assert!(catalogue.models.is_empty());
        assert_eq!(catalogue.failures.len(), 1, "{:?}", catalogue.failures);
        assert!(catalogue.failures.contains_key("local"));
    }

    #[test]
    fn a_stale_cache_is_refetched_and_a_fresh_one_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let path = cache_path(dir.path());
        let fresh = Catalogue {
            fetched_at: now(),
            models: vec![Discovered {
                reference: "openrouter/x-ai/grok-4.6".into(),
                context_window: Some(500_000),
                reasoning: true,
            }],
            failures: BTreeMap::new(),
        };
        fresh.write(&path);
        let read = Catalogue::read(&path).expect("the cache round-trips");
        assert!(read.is_fresh());
        assert_eq!(read.models, fresh.models);

        let stale = Catalogue {
            fetched_at: now() - TTL.as_secs() - 1,
            ..Default::default()
        };
        stale.write(&path);
        assert!(!Catalogue::read(&path).unwrap().is_fresh());
    }

    #[test]
    fn a_missing_or_corrupt_cache_is_simply_absent() {
        let dir = tempfile::tempdir().unwrap();
        let path = cache_path(dir.path());
        assert!(Catalogue::read(&path).is_none());
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"{ not json").unwrap();
        assert!(
            Catalogue::read(&path).is_none(),
            "a damaged cache is re-fetched, never a startup failure"
        );
    }
}
