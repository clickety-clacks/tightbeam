defmodule Tightbeam.VocabularyPurgeTest do
  # verification-papertrail-v1 A4: the producer subsystem's vocabulary is gone
  # from the substrate's seam files, exactly and executably. The quoted "tests"
  # / "smoke" clause is a regression tripwire, not a deletion check: the six
  # files carry zero quoted matches even at the cut — the config-key literals
  # lived only in the deleted producers.ex — so the clause guards against the
  # vocabulary re-entering, and the quoted form keeps it from false-hitting
  # Rust `mod tests` or prose. The bare word `producer` is deliberately NOT
  # swept: attests.producer columns are surviving history and remedy-producer
  # vocabulary is a different referent.
  use ExUnit.Case, async: true

  @swept_files [
    "lib/tightbeam/rules.ex",
    "lib/tightbeam/gateway.ex",
    "lib/tightbeam/wire/router.ex",
    "lib/tightbeam/assignments.ex",
    "cli/src/args.rs",
    "cli/src/dispatch.rs"
  ]

  @word_tokens [
    "run-tests",
    "run-smoke",
    "cancel-producer-job",
    "producer_jobs",
    "producer_job",
    "ProducerRunner",
    "ProducerSupervisor",
    "produced_verdict_kinds",
    "producer_unconfigured",
    "unknown_producer_job",
    "producer_failed",
    "tests-passed",
    "real-run-passed"
  ]

  @quoted_literals [~s("tests"), ~s("smoke")]

  test "lib/tightbeam/producers.ex does not exist" do
    refute File.exists?("lib/tightbeam/producers.ex")
  end

  test "the six seam files carry zero word-boundary producer-subsystem tokens" do
    for file <- @swept_files do
      contents = File.read!(file)

      for token <- @word_tokens do
        regex = Regex.compile!("\\b#{Regex.escape(token)}\\b")

        refute Regex.match?(regex, contents),
               "#{file} still contains the retired token #{inspect(token)}"
      end

      for literal <- @quoted_literals do
        refute String.contains?(contents, literal),
               "#{file} contains the retired quoted config-key literal #{literal}"
      end
    end
  end
end
