//! Slash-command completion.
//!
//! Two levels, because a command and its argument are different questions:
//! `/mod` completes to `/model`, and `/model ope` completes to a model this
//! agent is actually configured for. The candidates always come from live
//! state — the Lua tools this agent declared, the models in its own
//! `models.yml` — so the list cannot advertise something that does not exist.

/// One thing that can be completed to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// The text inserted when accepted.
    pub value: String,
    /// Shown beside it.
    pub detail: String,
}

/// A slash command and what its argument may be.
#[derive(Debug, Clone)]
pub struct Command {
    pub name: String,
    pub description: String,
    /// Completions for the argument. Empty means the argument is free text.
    pub arguments: Vec<Candidate>,
}

impl Command {
    pub fn new(name: &str, description: &str) -> Self {
        Self {
            name: name.to_string(),
            description: description.to_string(),
            arguments: Vec::new(),
        }
    }

    pub fn with_arguments(mut self, arguments: Vec<Candidate>) -> Self {
        self.arguments = arguments;
        self
    }
}

/// What to show, and what typing an acceptance would replace.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Completion {
    pub candidates: Vec<Candidate>,
    /// Byte offset in the input where the accepted value starts.
    pub replace_from: usize,
}

impl Completion {
    pub fn is_open(&self) -> bool {
        !self.candidates.is_empty()
    }
}

/// Work out what could come next.
///
/// Returns nothing unless the line is a slash command: ordinary prompts are for
/// the model, and popping a list open while someone writes prose would be
/// worse than useless.
pub fn complete(input: &str, commands: &[Command]) -> Completion {
    let Some(rest) = input.strip_prefix('/') else {
        return Completion::default();
    };

    match rest.split_once(' ') {
        // Still naming the command.
        None => {
            let candidates = commands
                .iter()
                .filter(|c| c.name.starts_with(rest))
                .map(|c| Candidate {
                    value: format!("/{}", c.name),
                    detail: c.description.clone(),
                })
                .collect();
            Completion {
                candidates,
                replace_from: 0,
            }
        }
        // Naming the argument to a command we know.
        Some((name, argument)) => {
            let Some(command) = commands.iter().find(|c| c.name == name) else {
                return Completion::default();
            };
            // Only the last word is being completed.
            let typed = argument.rsplit(' ').next().unwrap_or("");
            let candidates = command
                .arguments
                .iter()
                .filter(|a| a.value.starts_with(typed))
                .cloned()
                .collect();
            Completion {
                candidates,
                replace_from: input.len() - typed.len(),
            }
        }
    }
}

/// Apply a candidate to the input, leaving the cursor after it.
///
/// A command that takes an argument gains a trailing space, because the next
/// thing you will type is the argument.
pub fn accept(input: &str, completion: &Completion, index: usize, commands: &[Command]) -> String {
    let Some(candidate) = completion.candidates.get(index) else {
        return input.to_string();
    };
    let mut out = String::from(&input[..completion.replace_from]);
    out.push_str(&candidate.value);
    let wants_argument = commands
        .iter()
        .find(|c| format!("/{}", c.name) == candidate.value)
        .is_some_and(|c| !c.arguments.is_empty());
    if wants_argument {
        out.push(' ');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidates(values: &[&str]) -> Vec<Candidate> {
        values
            .iter()
            .map(|v| Candidate {
                value: v.to_string(),
                detail: String::new(),
            })
            .collect()
    }

    fn registry() -> Vec<Command> {
        vec![
            Command::new("help", "command reference"),
            Command::new("model", "inspect or select the model").with_arguments(candidates(&[
                "openai/gpt-5.6-luna",
                "anthropic/claude-opus-5",
            ])),
            Command::new("models", "list configured models"),
            Command::new("example", "a Lua tool"),
        ]
    }

    fn values(completion: &Completion) -> Vec<String> {
        completion
            .candidates
            .iter()
            .map(|c| c.value.clone())
            .collect()
    }

    #[test]
    fn a_bare_slash_offers_everything() {
        let completion = complete("/", &registry());
        assert_eq!(completion.candidates.len(), 4);
        assert!(values(&completion).contains(&"/model".to_string()));
    }

    #[test]
    fn typing_narrows_the_list() {
        let completion = complete("/mod", &registry());
        assert_eq!(
            values(&completion),
            vec!["/model".to_string(), "/models".to_string()]
        );
    }

    #[test]
    fn ordinary_text_never_opens_the_list() {
        // Someone writing a prompt must not have a menu appear over it.
        for input in ["", "how do I", "what about /model", "!ls"] {
            assert!(!complete(input, &registry()).is_open(), "{input:?}");
        }
    }

    #[test]
    fn an_argument_completes_from_live_state() {
        let completion = complete("/model ope", &registry());
        assert_eq!(values(&completion), vec!["openai/gpt-5.6-luna".to_string()]);
        assert_eq!(
            completion.replace_from,
            "/model ".len(),
            "only the argument is replaced"
        );
    }

    #[test]
    fn an_empty_argument_offers_all_of_them() {
        let completion = complete("/model ", &registry());
        assert_eq!(completion.candidates.len(), 2);
    }

    #[test]
    fn a_command_with_no_argument_completions_offers_nothing() {
        assert!(!complete("/help ", &registry()).is_open());
    }

    #[test]
    fn an_unknown_command_offers_nothing_rather_than_guessing() {
        assert!(!complete("/nope ", &registry()).is_open());
        assert!(!complete("/zzz", &registry()).is_open());
    }

    #[test]
    fn accepting_replaces_only_what_was_being_typed() {
        let commands = registry();
        let completion = complete("/mod", &commands);
        assert_eq!(
            accept("/mod", &completion, 0, &commands),
            "/model ",
            "and invites the argument"
        );

        let completion = complete("/model ope", &commands);
        assert_eq!(
            accept("/model ope", &completion, 0, &commands),
            "/model openai/gpt-5.6-luna"
        );
    }

    #[test]
    fn accepting_a_command_that_takes_no_argument_does_not_add_a_space() {
        let commands = registry();
        let completion = complete("/hel", &commands);
        assert_eq!(accept("/hel", &completion, 0, &commands), "/help");
    }

    #[test]
    fn accepting_an_index_that_is_not_there_leaves_the_input_alone() {
        let commands = registry();
        let completion = complete("/mod", &commands);
        assert_eq!(accept("/mod", &completion, 99, &commands), "/mod");
    }
}
