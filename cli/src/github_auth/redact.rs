pub(super) fn scrub_detail(detail: &str) -> String {
    let mut redacted = String::new();
    for word in detail.split_whitespace() {
        let cleaned = if word.contains("github_pat_") && !word.contains("://") {
            "[redacted]".to_owned()
        } else if let Some((scheme, rest)) = word.split_once("://") {
            if let Some((userinfo, host_path)) = rest.split_once('@') {
                // user:password AND token-as-username forms — gh accepts
                // https://ghp_xxx@host clones, so a bare token can be the
                // entire userinfo with no colon in sight.
                let userinfo_is_secret = userinfo.contains(':')
                    || userinfo.contains("github_pat_")
                    || ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]
                        .iter()
                        .any(|prefix| userinfo.contains(prefix));
                if userinfo_is_secret {
                    format!("{scheme}://[redacted]@{host_path}")
                } else {
                    word.to_owned()
                }
            } else {
                word.to_owned()
            }
        } else if word.starts_with("ghp_")
            || word.starts_with("gho_")
            || word.starts_with("ghu_")
            || word.starts_with("ghs_")
            || word.starts_with("ghr_")
        {
            "[redacted]".to_owned()
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
    }
}
