//! Awaited interception hooks and passive event fanout.

use futures::future::BoxFuture;
use serde_json::Value;
use std::sync::Arc;

pub type Hook = Arc<dyn Fn(Value) -> BoxFuture<'static, Result<Value, String>> + Send + Sync>;

#[derive(Default, Clone)]
pub struct Hooks {
    before_tool: Vec<Hook>,
    after_tool: Vec<Hook>,
}

impl Hooks {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn before_tool(mut self, hook: Hook) -> Self {
        self.before_tool.push(hook);
        self
    }
    pub fn after_tool(mut self, hook: Hook) -> Self {
        self.after_tool.push(hook);
        self
    }
    pub async fn run_before_tool(&self, mut event: Value) -> Result<Value, String> {
        for hook in &self.before_tool {
            event = hook(event).await?;
        }
        Ok(event)
    }
    pub async fn run_after_tool(&self, mut event: Value) -> Result<Value, String> {
        for hook in &self.after_tool {
            event = hook(event).await?;
        }
        Ok(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[tokio::test]
    async fn hooks_await_in_registration_order() {
        let hooks = Hooks::new()
            .before_tool(Arc::new(|mut v| {
                Box::pin(async move {
                    v["order"] = json!("a");
                    Ok(v)
                })
            }))
            .before_tool(Arc::new(|mut v| {
                Box::pin(async move {
                    v["second"] = v["order"].clone();
                    Ok(v)
                })
            }));
        let out = hooks
            .run_before_tool(json!({"command":"ls"}))
            .await
            .unwrap();
        assert_eq!(out["order"], "a");
        assert_eq!(out["second"], "a");
    }
    #[tokio::test]
    async fn hook_errors_stop_the_chain() {
        let hooks =
            Hooks::new().before_tool(Arc::new(|_| Box::pin(async { Err("blocked".into()) })));
        assert_eq!(
            hooks.run_before_tool(json!({})).await.unwrap_err(),
            "blocked"
        );
    }
}
