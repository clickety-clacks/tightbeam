#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Scrubbed(String);

impl Scrubbed {
    pub(super) fn new(value: impl AsRef<str>) -> Self {
        Self(scrub_detail(value.as_ref()))
    }

    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for Scrubbed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::ops::Deref for Scrubbed {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        self.as_str()
    }
}

pub(super) fn scrub_detail(detail: &str) -> String {
    let detail = redact_token_sequences(detail);
    let mut redacted = String::new();
    for word in detail.split_whitespace() {
        let cleaned = if let Some((scheme, rest)) = word.split_once("://") {
            if let Some((_userinfo, host_path)) = rest.split_once('@') {
                format!("{scheme}://[redacted]@{host_path}")
            } else {
                word.to_owned()
            }
        } else {
            word.to_owned()
        };
        if !redacted.is_empty() {
            redacted.push(' ');
        }
        redacted.push_str(&cleaned);
    }
    redacted
}

fn redact_token_sequences(detail: &str) -> String {
    const PREFIXES: [&str; 6] = ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"];

    let mut redacted = String::with_capacity(detail.len());
    let mut cursor = 0;
    while cursor < detail.len() {
        let next = PREFIXES
            .iter()
            .filter_map(|prefix| {
                detail[cursor..]
                    .find(prefix)
                    .map(|offset| (cursor + offset, prefix))
            })
            .min_by_key(|(offset, _prefix)| *offset);

        let Some((start, prefix)) = next else {
            redacted.push_str(&detail[cursor..]);
            break;
        };
        redacted.push_str(&detail[cursor..start]);

        let value_start = start + prefix.len();
        let mut end = value_start;
        for ch in detail[value_start..].chars() {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                end += ch.len_utf8();
            } else {
                break;
            }
        }

        if end == value_start {
            redacted.push_str(prefix);
            cursor = value_start;
        } else {
            redacted.push_str("[redacted]");
            cursor = end;
        }
    }
    redacted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrub_detail_redacts_tokens_and_credentialed_urls() {
        let detail =
            "https://user:github_pat_secret@github.com/org/repo.git failed ghp_secret gho_secret";
        let scrubbed = scrub_detail(detail);
        assert!(!scrubbed.contains("github_pat_secret"));
        assert!(!scrubbed.contains("ghp_secret"));
        assert!(!scrubbed.contains("gho_secret"));
        assert!(scrubbed.contains("https://[redacted]@github.com/org/repo.git"));
        assert_eq!(
            scrub_detail("https://alice@github.com/org/repo.git"),
            "https://[redacted]@github.com/org/repo.git"
        );

        let embedded =
            scrub_detail("provider_error=ghp_fixture_EMBEDDED, token=github_pat_11ABC_def");
        assert_eq!(embedded, "provider_error=[redacted], token=[redacted]");
    }

    #[test]
    fn scrubbed_values_cannot_expose_raw_provider_text_when_formatted() {
        let detail = Scrubbed::new(
            "provider_error=ghp_fixture_EMBEDDED at \
             https://x-access-token:ghp_REMOTE_SECRET@github.com/org/repo.git",
        );

        let rendered = format!("{detail}");
        assert_eq!(
            rendered,
            "provider_error=[redacted] at https://[redacted]@github.com/org/repo.git"
        );
    }
}
