//! `models.yml`, the agent's own model configuration.
//!
//! Read from the agent root and nowhere else — no home directory, no global
//! file, no environment-based discovery. Copy the directory and you copy which
//! models it can reach.
//!
//! One rule is enforced rather than encouraged: **every `apiKey` must be a
//! `$ENV_VAR` reference.** A literal key in this file would be committed,
//! copied along with the directory, and read by anything that can read the
//! agent — so it is refused at load, with the line that caused it.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("{path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{path}: {source}")]
    Yaml {
        path: String,
        #[source]
        source: serde_yaml::Error,
    },
    #[error(
        "provider {provider}: apiKey must be a $ENV_VAR reference, not a literal key \
         (got {got:?}). A key written here would be committed and copied with the agent."
    )]
    LiteralKey { provider: String, got: String },
    #[error("provider {provider}: {field} refers to ${var}, which is not set")]
    MissingEnv {
        provider: String,
        field: &'static str,
        var: String,
    },
    #[error("unknown model {spec:?}; configured: {known}")]
    UnknownModel { spec: String, known: String },
}

pub type Result<T, E = ConfigError> = std::result::Result<T, E>;

/// Which wire protocol a provider speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Api {
    OpenaiResponses,
    AnthropicMessages,
    /// Scripted, for tests. Never reaches the network.
    Fake,
}

/// Per-provider differences, kept here rather than as conditionals scattered
/// through the adapters.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Compat {
    /// Whether the endpoint accepts `store`.
    pub supports_store: bool,
    /// Whether a `developer` role is understood, or `system` must be used.
    pub supports_developer_role: bool,
    /// Whether `reasoning.effort` may be sent.
    pub supports_reasoning_effort: bool,
    /// What the token cap is called on this endpoint.
    pub max_tokens_field: String,
}

impl Default for Compat {
    fn default() -> Self {
        Self {
            supports_store: true,
            supports_developer_role: true,
            supports_reasoning_effort: true,
            max_tokens_field: "max_output_tokens".into(),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSpec {
    pub id: String,
    #[serde(default)]
    pub reasoning: bool,
    #[serde(default = "default_context")]
    pub context_window: u32,
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u32,
}

fn default_context() -> u32 {
    200_000
}
fn default_max_tokens() -> u32 {
    8192
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConfig {
    #[serde(default)]
    pub base_url: String,
    pub api: Api,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub models: Vec<ModelSpec>,
    #[serde(default)]
    pub compat: Compat,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Models {
    pub providers: BTreeMap<String, ProviderConfig>,
}

/// A provider and model, with every `$ENV` reference already resolved.
#[derive(Debug, Clone)]
pub struct Resolved {
    pub provider: String,
    pub api: Api,
    pub base_url: String,
    pub api_key: Option<String>,
    pub model: ModelSpec,
    pub compat: Compat,
}

impl Models {
    pub fn parse(text: &str, path: &str) -> Result<Self> {
        let models: Self = serde_yaml::from_str(text).map_err(|source| ConfigError::Yaml {
            path: path.to_string(),
            source,
        })?;
        // Fail at load, not at first request: a literal key is a mistake you
        // want to hear about before the agent starts.
        for (name, provider) in &models.providers {
            if let Some(key) = &provider.api_key
                && !key.starts_with('$')
            {
                return Err(ConfigError::LiteralKey {
                    provider: name.clone(),
                    got: key.clone(),
                });
            }
        }
        Ok(models)
    }

    pub fn load(path: &std::path::Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Io {
            path: path.display().to_string(),
            source,
        })?;
        Self::parse(&text, &path.display().to_string())
    }

    /// Every configured model, as `provider/id`.
    pub fn catalog(&self) -> Vec<String> {
        self.providers
            .iter()
            .flat_map(|(name, p)| p.models.iter().map(move |m| format!("{name}/{}", m.id)))
            .collect()
    }

    /// Resolve `provider/model`, `provider`, or a bare model id.
    pub fn resolve(&self, spec: &str) -> Result<Resolved> {
        self.resolve_with(spec, &|var| std::env::var(var).ok())
    }

    /// As [`Self::resolve`], with the environment injected.
    ///
    /// Tests use this rather than mutating the process environment, which is
    /// global and would race across the suite.
    pub fn resolve_with(
        &self,
        spec: &str,
        lookup: &dyn Fn(&str) -> Option<String>,
    ) -> Result<Resolved> {
        let (provider_name, model_id) = match spec.split_once('/') {
            Some((p, m)) => (Some(p), Some(m)),
            None => (None, Some(spec)),
        };

        let found = self.providers.iter().find_map(|(name, provider)| {
            if let Some(want) = provider_name
                && name != want
            {
                return None;
            }
            // `provider/` alone, or a provider name on its own, takes its first
            // model — the common "just use openai" case.
            let model = match model_id.filter(|m| !m.is_empty()) {
                Some(id) => provider.models.iter().find(|m| m.id == id)?,
                None => provider.models.first()?,
            };
            Some((name.clone(), provider.clone(), model.clone()))
        });

        let (name, provider, model) = found
            .or_else(|| {
                // A bare name that happens to be a provider.
                let provider = self.providers.get(spec)?;
                Some((
                    spec.to_string(),
                    provider.clone(),
                    provider.models.first()?.clone(),
                ))
            })
            .ok_or_else(|| ConfigError::UnknownModel {
                spec: spec.to_string(),
                known: self.catalog().join(", "),
            })?;

        Ok(Resolved {
            base_url: resolve_env(&name, "baseUrl", &provider.base_url, lookup)?,
            api_key: provider
                .api_key
                .as_deref()
                .map(|key| resolve_env(&name, "apiKey", key, lookup))
                .transpose()?,
            api: provider.api,
            compat: provider.compat.clone(),
            provider: name,
            model,
        })
    }
}

/// `$FOO` reads the environment; anything else is literal.
fn resolve_env(
    provider: &str,
    field: &'static str,
    value: &str,
    lookup: &dyn Fn(&str) -> Option<String>,
) -> Result<String> {
    let Some(var) = value.strip_prefix('$') else {
        return Ok(value.to_string());
    };
    lookup(var).ok_or_else(|| ConfigError::MissingEnv {
        provider: provider.to_string(),
        field,
        var: var.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
providers:
  openai:
    baseUrl: https://api.openai.com/v1
    api: openai-responses
    apiKey: $OPENAI_API_KEY
    models:
      - id: gpt-5.6-luna
        reasoning: true
        contextWindow: 200000
        maxTokens: 8192
  anthropic:
    baseUrl: https://api.anthropic.com
    api: anthropic-messages
    apiKey: $ANTHROPIC_API_KEY
    models:
      - id: claude-4-opus
    compat:
      supportsStore: false
      maxTokensField: max_tokens
"#;

    #[test]
    fn a_literal_api_key_is_refused_at_load() {
        let yaml = "providers:\n  openai:\n    api: openai-responses\n    apiKey: sk-realkey123\n";
        let err = Models::parse(yaml, "models.yml").unwrap_err();
        assert!(matches!(err, ConfigError::LiteralKey { .. }), "got {err}");
        assert!(
            err.to_string().contains("committed"),
            "and it says why: {err}"
        );
    }

    #[test]
    fn a_bare_env_name_without_the_dollar_is_also_refused() {
        // `OPENAI_API_KEY` looks like a reference but is a literal value.
        let yaml = "providers:\n  openai:\n    api: openai-responses\n    apiKey: OPENAI_API_KEY\n";
        assert!(Models::parse(yaml, "models.yml").is_err());
    }

    /// A fixed environment, so nothing here depends on the real one.
    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let pairs: Vec<(String, String)> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |var| pairs.iter().find(|(k, _)| k == var).map(|(_, v)| v.clone())
    }

    #[test]
    fn env_references_resolve_and_missing_ones_say_which() {
        let models = Models::parse(SAMPLE, "models.yml").unwrap();
        let resolved = models
            .resolve_with(
                "openai/gpt-5.6-luna",
                &env(&[("OPENAI_API_KEY", "resolved-key")]),
            )
            .unwrap();
        assert_eq!(resolved.api_key.as_deref(), Some("resolved-key"));
        assert_eq!(resolved.api, Api::OpenaiResponses);

        let err = models.resolve_with("anthropic", &env(&[])).unwrap_err();
        assert!(err.to_string().contains("ANTHROPIC_API_KEY"), "{err}");
    }

    #[test]
    fn a_model_can_be_named_several_ways() {
        let models = Models::parse(SAMPLE, "models.yml").unwrap();
        let lookup = env(&[("OPENAI_API_KEY", "k")]);
        for spec in ["openai/gpt-5.6-luna", "openai", "gpt-5.6-luna"] {
            let resolved = models
                .resolve_with(spec, &lookup)
                .unwrap_or_else(|e| panic!("{spec}: {e}"));
            assert_eq!(resolved.model.id, "gpt-5.6-luna", "{spec}");
        }
    }

    #[test]
    fn an_unknown_model_lists_what_is_configured() {
        let models = Models::parse(SAMPLE, "models.yml").unwrap();
        let err = models.resolve("nope/nothing").unwrap_err();
        assert!(err.to_string().contains("gpt-5.6-luna"), "{err}");
        assert!(err.to_string().contains("claude-4-opus"), "{err}");
    }

    #[test]
    fn compat_defaults_are_sane_and_overridable() {
        let models = Models::parse(SAMPLE, "models.yml").unwrap();
        let lookup = env(&[("OPENAI_API_KEY", "k"), ("ANTHROPIC_API_KEY", "k")]);
        let openai = models.resolve_with("openai", &lookup).unwrap();
        assert!(openai.compat.supports_store, "the default");
        assert_eq!(openai.compat.max_tokens_field, "max_output_tokens");

        let anthropic = models.resolve_with("anthropic", &lookup).unwrap();
        assert!(!anthropic.compat.supports_store, "overridden per provider");
        assert_eq!(anthropic.compat.max_tokens_field, "max_tokens");
    }

    #[test]
    fn model_defaults_fill_in_when_omitted() {
        let models = Models::parse(SAMPLE, "models.yml").unwrap();
        let claude = models
            .resolve_with(
                "anthropic/claude-4-opus",
                &env(&[("ANTHROPIC_API_KEY", "k")]),
            )
            .unwrap();
        assert_eq!(claude.model.context_window, 200_000);
        assert_eq!(claude.model.max_tokens, 8192);
        assert!(!claude.model.reasoning);
    }

    #[test]
    fn the_scaffolded_models_file_is_valid() {
        // The template `leve init` writes must itself load.
        let template = include_str!("../templates/models.yml");
        let models = Models::parse(template, "models.yml").expect("the scaffold parses");
        assert!(!models.catalog().is_empty());
    }
}
