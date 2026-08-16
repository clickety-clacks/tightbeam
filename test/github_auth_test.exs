defmodule Tightbeam.GithubAuthTest do
  use ExUnit.Case, async: true

  alias Tightbeam.GithubAuth

  test "config_dir is one shared dir under auth, not per-hostname" do
    assert GithubAuth.config_dir("/base") == "/base/auth/github/gh"
  end

  test "env pins GH_CONFIG_DIR unconditionally" do
    assert GithubAuth.env("/base") == [{"GH_CONFIG_DIR", "/base/auth/github/gh"}]
  end

  test "hostname recognizes github.com remotes in every git URL form" do
    assert GithubAuth.hostname("https://github.com/org/repo.git") == "github.com"
    assert GithubAuth.hostname("http://github.com/org/repo") == "github.com"
    assert GithubAuth.hostname("ssh://git@github.com/org/repo.git") == "github.com"
    assert GithubAuth.hostname("git@github.com:org/repo.git") == "github.com"
    assert GithubAuth.hostname("https://gist.github.com/org/id") == "gist.github.com"
  end

  test "hostname rejects non-github and malformed remotes" do
    assert GithubAuth.hostname("https://gitlab.com/org/repo.git") == nil
    assert GithubAuth.hostname("git@bitbucket.org:org/repo.git") == nil
    # A lookalike suffix is not a subdomain.
    assert GithubAuth.hostname("https://notgithub.com/org/repo") == nil
    assert GithubAuth.hostname("/local/path/repo.git") == nil
    assert GithubAuth.hostname(nil) == nil
  end

  test "scrub_detail redacts every github token shape and credentialed URL" do
    assert GithubAuth.scrub_detail("token ghp_abc123 leaked") == "token [redacted] leaked"
    assert GithubAuth.scrub_detail("gho_abc ghu_abc ghs_abc ghr_abc") ==
             "[redacted] [redacted] [redacted] [redacted]"

    assert GithubAuth.scrub_detail("fine github_pat_11ABC_def failed") ==
             "fine [redacted] failed"

    assert GithubAuth.scrub_detail("https://user:secret@github.com/org/repo.git") ==
             "https://[redacted]@github.com/org/repo.git"
  end
end
