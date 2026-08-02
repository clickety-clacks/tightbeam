//! Replay a pty transcript as a terminal screen, and read the finished screen.
//!
//! `claude setup-token` prints the token through a differential-repaint TUI, and a
//! transcript of that TUI is not the text it displayed. Two separate things corrupt a
//! naive scan of the raw bytes, and BOTH have to be undone:
//!
//!   1. The renderer emits only the cells that changed since the previous frame and
//!      jumps the cursor over the rest with CHA (`CSI n G`). A character identical to
//!      the one already on screen at that column is NEVER emitted, so the transcript
//!      is missing characters, not merely polluted with escapes. Stripping escapes and
//!      matching therefore yields a well-formed token that is silently WRONG.
//!   2. The TUI hard-wraps at the terminal width itself, emitting `\r\r\n` rather than
//!      relying on the terminal's autowrap. The token is a plain Text node, so at any
//!      width under its length it arrives split across two rows.
//!
//! Replaying onto a screen undoes (1), because a skipped cell still holds the identical
//! character an earlier frame put there. Rejoining full-width rows undoes (2).
//!
//! The width is taken from the transcript rather than from any terminal: it is the
//! longest row the replay produced. Nothing can be wider than the terminal, so it is
//! never an over-estimate, and it rejoins ordinary wrapped prose correctly.
//!
//! It does NOT pin the token. A screen has more than one wrapping width: the OAuth URL
//! is unboxed and wraps at the terminal, while the token panel wraps at its own content
//! width, which is narrower. So the token's first row can be SHORTER than the widest row
//! on screen — at which point the width-based rejoin does not fire, the token's rows stay
//! separate, and the first of them is by itself a well-formed `sk-ant-oat…` string of
//! plausible length. That is the dangerous shape: not a malformed token that fails a
//! check, but a truncated one that passes every check there is and 401s a month later.
//! Measured headlessly (`stty size` = 0 0, TERM unset) it banked 79 characters of a
//! 108-character token and reported success.
//!
//! So the token is reassembled from its OWN rows, bounded by the blank rows that claude's
//! `gap:1` panel leaves around it, and identified by the one thing a credential cannot
//! change: it carries no whitespace. The single inferred width still does the prose, and
//! no longer decides the credential.
//!
//! The ceremony now owns the pty and sets its geometry directly. Replay still derives
//! the rendered width from bytes, so capture does not smuggle a width or token-length
//! assumption back into the read side.

use vte::{Params, Parser, Perform};

/// A terminal screen, grown to fit whatever the transcript addressed.
///
/// Deliberately unbounded rather than a fixed height with scrollback: the transcript
/// does not record the pty's height, and a screen that never scrolls loses nothing —
/// the TUI addresses rows relatively (`CSI 1 A`) and never relies on clamping at the
/// top of a viewport.
#[derive(Default)]
struct Screen {
    rows: Vec<Vec<char>>,
    row: usize,
    column: usize,
    saved: (usize, usize),
}

impl Screen {
    fn put(&mut self, character: char) {
        while self.rows.len() <= self.row {
            self.rows.push(Vec::new());
        }
        let row = &mut self.rows[self.row];
        while row.len() <= self.column {
            row.push(' ');
        }
        row[self.column] = character;
        self.column += 1;
    }

    fn erase_in_row(&mut self, from: usize, to: Option<usize>) {
        let Some(row) = self.rows.get_mut(self.row) else {
            return;
        };
        let to = to.unwrap_or(row.len());
        for column in from..to.min(row.len()) {
            row[column] = ' ';
        }
    }
}

impl Perform for Screen {
    fn print(&mut self, character: char) {
        self.put(character);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x08 => self.column = self.column.saturating_sub(1),
            b'\t' => self.column = (self.column / 8 + 1) * 8,
            b'\n' | 0x0b | 0x0c => self.row += 1,
            b'\r' => self.column = 0,
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, _intermediates: &[u8], ignore: bool, action: char) {
        if ignore {
            return;
        }
        let argument = |index: usize, default: usize| {
            params
                .iter()
                .nth(index)
                .and_then(|values| values.first().copied())
                .filter(|value| *value != 0)
                .map(usize::from)
                .unwrap_or(default)
        };
        match action {
            'A' => self.row = self.row.saturating_sub(argument(0, 1)),
            'B' | 'e' => self.row += argument(0, 1),
            'C' | 'a' => self.column += argument(0, 1),
            'D' => self.column = self.column.saturating_sub(argument(0, 1)),
            'E' => {
                self.row += argument(0, 1);
                self.column = 0;
            }
            'F' => {
                self.row = self.row.saturating_sub(argument(0, 1));
                self.column = 0;
            }
            'G' | '`' => self.column = argument(0, 1) - 1,
            'd' => self.row = argument(0, 1) - 1,
            'H' | 'f' => {
                self.row = argument(0, 1) - 1;
                self.column = argument(1, 1) - 1;
            }
            'J' => match argument(0, 0) {
                0 => {
                    self.erase_in_row(self.column, None);
                    self.rows.truncate(self.row + 1);
                }
                1 => {
                    for row in 0..self.row.min(self.rows.len()) {
                        self.rows[row].clear();
                    }
                    self.erase_in_row(0, Some(self.column + 1));
                }
                _ => self.rows.clear(),
            },
            'K' => match argument(0, 0) {
                0 => self.erase_in_row(self.column, None),
                1 => self.erase_in_row(0, Some(self.column + 1)),
                _ => self.erase_in_row(0, None),
            },
            'X' => self.erase_in_row(self.column, Some(self.column + argument(0, 1))),
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        if !intermediates.is_empty() {
            return;
        }
        match byte {
            b'7' => self.saved = (self.row, self.column),
            b'8' => (self.row, self.column) = self.saved,
            b'D' => self.row += 1,
            b'E' => {
                self.row += 1;
                self.column = 0;
            }
            b'M' => self.row = self.row.saturating_sub(1),
            b'c' => {
                self.rows.clear();
                self.row = 0;
                self.column = 0;
            }
            _ => {}
        }
    }
}

/// The lines the transcript actually displayed, with the TUI's own hard wrapping undone.
pub fn displayed_lines(transcript: &[u8]) -> Vec<String> {
    let mut screen = Screen::default();
    let mut parser = Parser::new();
    parser.advance(&mut screen, transcript);

    let rows = screen
        .rows
        .iter()
        .map(|row| row.iter().collect::<String>().trim_end().to_owned())
        .collect::<Vec<_>>();
    let width = rows
        .iter()
        .map(|row| row.chars().count())
        .max()
        .unwrap_or(0);

    let mut lines = Vec::new();
    let mut wrapped = String::new();
    for row in rows {
        // A BLANK row is a gap, never a continuation, so it ends the run it follows and
        // survives as a line of its own. Absorbing it as a run's terminator — which is
        // what happens to any row that is not full width — loses it exactly when the run
        // ended flush at the width, and the gap after the token is load-bearing.
        if row.is_empty() {
            if !wrapped.is_empty() {
                lines.push(std::mem::take(&mut wrapped));
            }
            lines.push(String::new());
            continue;
        }

        let continues = width > 0 && row.chars().count() == width;
        wrapped.push_str(&row);
        if !continues {
            lines.push(std::mem::take(&mut wrapped));
        }
    }
    if !wrapped.is_empty() {
        lines.push(wrapped);
    }
    lines
}

/// What the replayed screen holds where a token should be.
///
/// One reading, shared by `capture_setup_token`, `capture_note`, and `refusal_reason`,
/// so the capture and the explanation can never describe two different screens.
enum Reading {
    /// The one unbroken run standing below the token heading, rejoined from its rows.
    Token { token: String, rows: usize },
    /// No token panel heading was visible on the replayed screen.
    Absent { lines: usize },
    /// A token panel was visible, but its boundaries did not make one credential
    /// candidate decidable.
    Ambiguous { reason: &'static str },
}

/// Read the credential off the replayed token panel by screen structure.
///
/// The provider is free to change the credential's prefix, length, and alphabet, so none
/// of those may be a rule here. Two things the credential cannot change, because the
/// things that consume it forbid it:
///
///   * It contains no whitespace. It travels as the credentials component of an
///     `Authorization: Bearer <token>` header -- the token68 production of RFC 9110, whose
///     alphabet has no space in it. (The header VALUE does contain a space, after
///     `Bearer`; it is the token itself that cannot, and that is the part read here.) This
///     is what makes joining wrapped rows exact rather than lossy: the row breaks are the
///     terminal's, not the credential's, so trimming them back off cannot remove a
///     character the credential had.
///   * It is therefore distinguishable from the panel's prose. The heading and the "store
///     this token securely" footer are sentences; the credential is one unbroken run.
///
/// So the body is the ONE unbroken run standing immediately after the heading, and a
/// screen showing a second unbroken run after it is refused rather than resolved. That
/// second run is the shape both silent-truncation defects take: a credential split by a
/// blank row reads as two runs, and so does a panel that painted two candidates. Taking
/// the first of them is how a well-formed fragment gets banked (#80). There is nothing on
/// the screen that says which one is the credential, so the screen does not get to decide.
///
/// What this does NOT do, stated plainly so nobody rests weight on it: it does not make
/// same-run ambiguity impossible. A run that is genuinely one unbroken sequence but carries
/// a stale suffix -- a previous paint the replay did not clear -- still reads as one
/// candidate and is returned. The screen cannot tell those apart, and the thing that
/// actually catches them is provider validation before banking. That is a real defence, but
/// it lives elsewhere, so do not read the rule above as making capture self-sufficient.
///
/// Refusals never carry candidate bytes into their diagnostic.
fn read_token(lines: &[String]) -> Reading {
    let runs = lines
        .split(|line| line.trim().is_empty())
        .filter(|run| !run.is_empty())
        .map(|run| {
            (
                run.iter()
                    .map(|line| line.trim())
                    .collect::<Vec<_>>()
                    .join(""),
                run.len(),
            )
        })
        .collect::<Vec<_>>();
    let Some(heading) = runs.iter().rposition(|run| {
        let heading = run.0.to_ascii_lowercase();
        heading.contains("oauth") && heading.contains("token")
    }) else {
        return Reading::Absent { lines: lines.len() };
    };

    let body = &runs[heading + 1..];
    let unbroken = body
        .iter()
        .filter(|(run, _)| !run.is_empty() && !run.chars().any(char::is_whitespace))
        .count();
    if unbroken > 1 {
        return Reading::Ambiguous {
            reason: "more than one unbroken credential body stood below the OAuth-token heading, \
                     and nothing on the screen says which of them is the token",
        };
    }
    let Some((token, rows)) = body.first() else {
        return Reading::Ambiguous {
            reason: "the OAuth-token panel contained no non-empty credential body",
        };
    };
    if unbroken == 0 || token.chars().any(char::is_whitespace) {
        return Reading::Ambiguous {
            reason: "the run below the OAuth-token heading carried whitespace, so it is prose or \
                     a credential welded to the panel footer, not a credential on its own",
        };
    }

    Reading::Token {
        token: token.to_owned(),
        rows: *rows,
    }
}

/// The authorization URL visible on the replayed screen.
///
/// Both provider CLIs may decorate or hard-wrap their browser URL. Reading the screen
/// recovers the operator-visible URL without treating OSC hyperlink payloads as text.
pub fn authorization_url(transcript: &[u8]) -> Option<String> {
    let raw = String::from_utf8_lossy(transcript);
    for escape in raw.split("\x1b]8;").skip(1) {
        let Some(end) = escape.find('\x07') else {
            continue;
        };
        let payload = &escape[..end];
        let Some((_, url)) = payload.split_once(';') else {
            continue;
        };
        if url.starts_with("https://") || url.starts_with("http://") {
            return Some(url.to_owned());
        }
    }

    // A pipe/line-oriented CLI such as `codex login --device-auth` terminates the URL
    // with a newline. Do not report an in-flight prefix merely because the latest read
    // happened to end in the middle of the write.
    if !transcript.ends_with(b"\n") {
        return None;
    }

    displayed_lines(transcript)
        .into_iter()
        .flat_map(|line| {
            line.split_whitespace()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .filter_map(|word| {
            let url = word
                .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
                .trim_end_matches(|character| matches!(character, '.' | ',' | ')' | ']'));
            (url.starts_with("https://") || url.starts_with("http://")).then(|| url.to_owned())
        })
        .next()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A FABRICATED token. Not derived from any real credential, and self-evidently so:
    /// it says what it is, and the tail is a repeating digit run.
    ///
    /// Only its provider prefix and alphabet are real and public. Its former 108-character
    /// length remains useful for replaying the historical wrap fixtures, but is no longer
    /// an acceptance rule: the 2026-08-01 live ceremony produced 109 characters.
    const TOKEN: &str = "sk-ant-oat01-SYNTHETIC-FIXTURE-NOT-A-REAL-TOKEN-012345678901234567890123456789012345678901234567890123456789";

    fn token_panel(token: &str) -> String {
        format!(
            "Your OAuth token (valid for 1 year):\r\n\r\n{token}\r\n\r\nStore this token securely.\r\n"
        )
    }

    #[test]
    fn the_fixture_is_provider_shaped_and_synthetic() {
        assert_eq!(TOKEN.chars().count(), 108);
        assert!(TOKEN.starts_with("sk-ant-oat01-"));
        assert!(
            TOKEN.contains("SYNTHETIC"),
            "this fixture must stay provably fabricated: it lives in a public repo"
        );
    }

    const URL: &str = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=Pc-oTIMUQocUA8wvn5TtJVCEDBZEzuNPuBGwxYh6ltk";

    /// How the modeled renderer treats cells its new frame does not reach.
    ///
    /// claude 2.1.220 has been observed doing BOTH. The live capture of 2026-07-27
    /// showed rows cleared by writing spaces over their tails (no erase sequences exist
    /// in any real transcript, so padding is the only clearing there is). Issue #5 then
    /// showed the opposite in the wild: at 110 columns a stale non-space cell survived
    /// at column 109, right after the 108-char token — a repaint that did NOT pad past
    /// its own content. An earlier version of this model stated padding as a universal
    /// property, and that fixture structurally could not represent the screen the
    /// operator actually got. So the model carries both behaviors, and the capture
    /// layer must be exact under the first and never-wrong under the second.
    #[derive(Clone, Copy, PartialEq)]
    enum Erase {
        /// Every painted row is padded with spaces to the full terminal width, so no
        /// cell of a prior frame survives.
        PadsToWidth,
        /// A row is painted only to its own content; whatever a prior frame left past
        /// that keeps standing. Gap rows painted over old content leave ALL of it.
        LeavesStaleCells,
    }

    /// A model of the claude TUI's renderer, as observed live at 2.1.220.
    ///
    /// Five properties, and every one of them was got WRONG in an early draft of this
    /// fixture, in each case producing a test that passed while proving nothing. They are
    /// listed because a future reader tightening this model will otherwise re-break them:
    ///
    ///   1. REPAINT IS IN PLACE. A frame is diffed against what is already on those rows,
    ///      not written to fresh ones. Diffing against fresh rows loses the skipped cells
    ///      for real, so the test fails for the opposite of the reason it should.
    ///   2. NO ERASE SEQUENCES EXIST. Neither CSI K nor CSI J appears anywhere in a real
    ///      transcript. Whether the renderer clears a shrinking row by writing spaces
    ///      over its tail is [`Erase`]'s axis: it has been seen both padding and leaving
    ///      stale cells, so both modes are modeled and swept.
    ///   3. THE CURSOR MOVES BY ROWS ACTUALLY PAINTED. Walking back up by the new frame's
    ///      height instead of the previous frame's silently shifts every subsequent frame
    ///      down the screen.
    ///   4. BLANK ROWS ARE LOAD-BEARING. `gap:1` rows are rows. Dropping them collapses
    ///      the panel and, worse, removes the blank row that makes an exactly-full-width
    ///      token decidable.
    ///   5. LINES ARE HARD-WRAPPED BY THE RENDERER, at the terminal width, with `\r\r\n`
    ///      between rows -- not by the terminal's autowrap.
    struct Tui {
        width: usize,
        erase: Erase,
        painted: Vec<String>,
        transcript: String,
    }

    impl Tui {
        fn new(width: usize) -> Self {
            Self::with_erase(width, Erase::PadsToWidth)
        }

        /// The issue-#5 renderer: repaint without erase, stale cells surviving.
        fn without_erase(width: usize) -> Self {
            Self::with_erase(width, Erase::LeavesStaleCells)
        }

        fn with_erase(width: usize, erase: Erase) -> Self {
            Self {
                width,
                erase,
                painted: Vec::new(),
                transcript: String::from("\x1b[?25l"),
            }
        }

        fn render(&mut self, lines: &[&str]) -> &mut Self {
            let mut rows = lines
                .iter()
                .flat_map(|line| {
                    let characters = line.chars().collect::<Vec<_>>();
                    if characters.is_empty() {
                        // A gap row still occupies a row.
                        return vec![String::new()];
                    }
                    characters
                        .chunks(self.width)
                        .map(|chunk| chunk.iter().collect::<String>())
                        .collect::<Vec<_>>()
                })
                .collect::<Vec<_>>();
            let height = rows.len().max(self.painted.len());
            if self.erase == Erase::PadsToWidth {
                rows.resize(height, String::new());
                for row in &mut rows {
                    while row.chars().count() < self.width {
                        row.push(' ');
                    }
                }
            }

            if !self.painted.is_empty() {
                self.transcript
                    .push_str(&format!("\r\x1b[{}A", self.painted.len()));
            }
            // What each row holds afterwards: the new content, plus whatever old cells
            // it did not reach. Under PadsToWidth the new content always reaches the
            // full width, so nothing survives; under LeavesStaleCells the tail of a
            // wider prior frame keeps standing -- that surviving tail IS issue #5.
            let mut merged = Vec::with_capacity(height);
            for index in 0..height {
                let was = self.painted.get(index).map(String::as_str).unwrap_or("");
                let now = rows.get(index).map(String::as_str).unwrap_or("");
                self.transcript.push_str(&repaint(was, now));
                self.transcript.push_str("\r\r\n");
                let shown = now.chars().count();
                merged.push(now.chars().chain(was.chars().skip(shown)).collect());
            }
            self.painted = merged;
            self
        }

        fn transcript(&self) -> &str {
            &self.transcript
        }
    }

    /// Emit only the cells that differ from what the row already holds, jumping over the
    /// rest with CHA. A cell whose new character equals the old one is NEVER emitted --
    /// which is why the transcript is missing characters and the screen is not.
    fn repaint(prior: &str, next: &str) -> String {
        let prior: Vec<char> = prior.chars().collect();
        let next: Vec<char> = next.chars().collect();
        let mut out = String::new();
        let mut column = 0;
        while column < next.len() {
            if prior.get(column) == Some(&next[column]) {
                column += 1;
                continue;
            }
            let start = column;
            while column < next.len() && prior.get(column) != Some(&next[column]) {
                column += 1;
            }
            out.push_str(&format!("\x1b[{}G", start + 1));
            out.extend(&next[start..column]);
        }
        out
    }

    /// What sat on the token's rows immediately before it was painted over them. Every
    /// eighth cell already holds the token's own character, so the repaint jumps over it
    /// and never emits it -- at every width, rather than by the coincidence that decides
    /// it in the wild.
    fn stale_frame() -> String {
        TOKEN
            .chars()
            .enumerate()
            .map(|(column, character)| if column % 8 == 0 { character } else { '#' })
            .collect()
    }

    /// Small widths split the token inside the `sk-ant-oat` prefix itself; 108 is the
    /// token's exact length; above it nothing wraps at all.
    const SWEEP_WIDTHS: [usize; 17] = [
        3, 5, 7, 9, 11, 13, 40, 60, 72, 80, 100, 107, 108, 109, 120, 200, 400,
    ];

    /// The panel claude 2.1.220 renders, blank lines included: its Box carries gap:1,
    /// so every child is separated by an empty row. That blank row after the token is
    /// what tells a token exactly as wide as the terminal apart from one that wrapped
    /// -- without it the two are indistinguishable in a transcript. The frame before
    /// the token lands is laid out the same way, so the stale characters sit on the
    /// very rows the token is about to be painted over.
    fn ceremony_transcript(width: usize, erase: Erase, stale: &str) -> String {
        let label = "Your OAuth token (valid for 1 year):";
        let footer = "Store this token securely. You won't be able to see it again.";
        let mut tui = Tui::with_erase(width, erase);
        tui.render(&["Browser didn't open? Use the url below to sign in", "", URL])
            .render(&[label, "", stale, "", footer])
            .render(&[label, "", TOKEN, "", footer]);
        tui.transcript().to_owned()
    }

    /// The production geometry under the harsher no-erase renderer. The current
    /// 109-character shape reaches the row edge, so no stale suffix survives.

    // --------------------------------------------------------------------------------
    // Issue #5's geometry: `onboard anthropic` at a 110-column terminal. The OAuth URL
    // hard-wrapped at 110 and pinned the widest row; the 108-char token did NOT wrap
    // (108 < 110), but the reconstructed token line came back 109 characters -- one
    // stale non-space cell at column 109, left by a prior frame the token's repaint
    // never cleared. The prior capture rule required the token to be alone on its line,
    // so it refused at an ordinary terminal width and told the operator to resize.
    // --------------------------------------------------------------------------------

    /// The ceremony screen issue #5 reported, rendered by the no-erase renderer at
    /// `width`, where the row the token lands on previously held `stale_row`. The
    /// prelude is identical in every frame so the only dirty row is the token's own.
    fn issue_5_screen(width: usize, stale_row: &str) -> String {
        let prelude = "Browser didn't open? Use the url below to sign in";
        let label = "Your OAuth token (valid for 1 year):";
        let footer = "Store this token securely. You won't be able to see it again.";
        let mut tui = Tui::without_erase(width);
        tui.render(&[prelude, "", URL])
            .render(&[prelude, "", URL, "", label, "", stale_row, "", footer])
            .render(&[prelude, "", URL, "", label, "", TOKEN, "", footer]);
        tui.transcript().to_owned()
    }

    /// Issue #5 EXACTLY: 110 columns, token line 109 characters -- the 108-char token
    /// plus one stale cell at column 109. Capture keeps the entire structurally bounded
    /// candidate; it must never truncate at a guessed alphabet boundary.

    /// Boundaries around the reported geometry: the stale tail makes the token line
    /// exactly the terminal width (so it rejoins as a full-width row), at 110 and 109
    /// columns, and one past the width (so one stale cell wraps to the next row and
    /// the rejoin welds it back). All must retain the complete panel body.

    /// Issue #5's flagged near-miss: the stale cell holds a token-ALPHABET character,
    /// so the 109-char line is an unbroken run and nothing marks where the token ends.
    /// A provider-shaped 109-character run is accepted by shape, not rejected because an
    /// older vendor version happened to mint 108-character tokens. Live validation is the
    /// authority for whether those bytes are a credential.

    /// Control: the same layout with NO stale tail, at the boundary widths -- shows
    /// the assertions above are about the stale cell, not the widths.

    /// The CLI-owned 109-column pty keeps the observed token on one row.
    /// The width is presentation geometry only; capture remains shape-based.

    /// Token-alphabet cells directly adjacent to a wrapped token are indistinguishable
    /// from the provider-shaped run without a length contract. Capture returns the whole
    /// shape; authenticated validation remains the gate that prevents banking wrong bytes.

    /// The shape reported from shrdlu: characters inside the token were never emitted,
    /// because the frame underneath already held the same character at those columns.
    /// Column 7 falls inside `sk-ant-oat`, so even the prefix arrives broken.

    /// A shorter frame painted over a longer one WITHOUT clearing the tail: the
    /// leftover cells sit on the token's row and the rejoin welds them onto it. The
    /// welded tail here leaves the token alphabet immediately (`/` at the seam), so the
    /// capture keeps the whole bounded panel body instead of guessing where a future
    /// credential alphabet ends.

    /// The two corruptions at once, stated rather than stumbled into: the wrap boundary
    /// falls INSIDE the `sk-ant-oat` prefix, and cells inside that prefix were skipped by
    /// the repaint because the frame underneath already held the same characters. Neither
    /// half is recoverable from the bytes alone; both are recoverable from the screen.

    /// A token displayed plainly, with no repaint and no wrapping -- the shape the old
    /// whitespace scan handled, kept so the fix is not narrower than what it replaces.
    /// Capture is provider-shape-based rather than tied to this fixture's length.

    /// A shorter provider-shaped run is still extracted; the authenticated validation
    /// call, not a locally remembered vendor length, decides whether it is genuine.

    /// An OSC 8 hyperlink's payload must be consumed as an escape, never printed. The
    /// real transcript wraps the OAuth URL in one, and its PKCE blob is made of exactly
    /// the characters a token is made of -- printed into the screen it would corrupt the
    /// row the token is read from. This is the case that decided the `vte` dependency.

    /// Invalid UTF-8 must not discard the transcript. `read_to_string` errored on it and
    /// `unwrap_or_default` turned that into an empty string, so one stray byte was
    /// indistinguishable from claude printing nothing at all.

    /// The reconstruction, checked against a REAL `claude setup-token` transcript.
    ///
    /// Recorded on eezo at claude 2.1.220 on a 24x80 pty, with `open` stubbed so no
    /// browser launched, and killed before any authorization code was entered -- so the
    /// fixture holds no credential (grep it for `sk-ant`: zero hits). What it does hold
    /// is the rendering this defect is about: prose whose spaces were never emitted, and
    /// a long line the TUI hard-wrapped into 80-column rows.
    ///
    /// It attests to its own expected value. The OAuth URL appears twice -- once whole
    /// inside an OSC 8 hyperlink, and once as visible text broken across rows -- so
    /// comparing the reconstruction to the hyperlink checks recorded reality rather than
    /// a transcript the test wrote for itself to pass.
    const RECORDED: &[u8] = include_bytes!("fixtures/claude-setup-token-2.1.220-80col.log");

    fn recorded_hyperlink_url() -> String {
        let text = String::from_utf8_lossy(RECORDED);
        let start = text.find("\x1b]8;id=").expect("a hyperlink was emitted");
        let payload = &text[start + "\x1b]8;".len()..];
        let end = payload.find('\x07').expect("BEL terminates the hyperlink");
        payload[..end].split_once(';').expect("id;url").1.to_owned()
    }

    #[test]
    fn the_recorded_wrapped_url_comes_back_exactly_as_its_hyperlink_states_it() {
        let expected = recorded_hyperlink_url();
        assert!(
            expected.chars().count() > 200,
            "the fixture's URL should be far longer than a token"
        );

        // The defect as a property of these exact bytes. The URL survives in the raw
        // transcript ONLY inside the OSC 8 hyperlink -- which is why it can serve as the
        // oracle here. Strip the escapes the way a naive fix would and the DISPLAYED
        // copy is gone, because the TUI broke it across rows. A token gets no hyperlink,
        // so for a token there is no second copy to fall back on.
        let raw = String::from_utf8_lossy(RECORDED);
        let visible = raw
            .split('\x1b')
            .map(|piece| match piece.find('\x07') {
                Some(end) if piece.starts_with(']') => &piece[end + 1..],
                _ => piece,
            })
            .collect::<String>();
        assert!(
            !visible.contains(&expected),
            "with the hyperlink escapes gone, no contiguous copy of the URL is left"
        );
        assert!(
            displayed_lines(RECORDED)
                .iter()
                .any(|line| line.contains(&expected)),
            "the replayed screen must show it whole"
        );
        assert_eq!(
            authorization_url(RECORDED).as_deref(),
            Some(expected.as_str())
        );
    }

    #[test]
    fn an_unterminated_url_prefix_is_not_printed_as_the_authorization_url() {
        let partial = b"Opening browser\nhttps://example.test/authorize?code=part";
        assert_eq!(authorization_url(partial), None);

        let complete = b"Opening browser\nhttps://example.test/authorize?code=part\n";
        assert_eq!(
            authorization_url(complete).as_deref(),
            Some("https://example.test/authorize?code=part")
        );
    }

    #[test]
    fn recorded_prose_the_tui_never_emitted_contiguously_reads_back_whole() {
        let screen = displayed_lines(RECORDED).join("\n");
        // Every space inside these was skipped by a cursor jump and never written.
        for phrase in [
            "Welcome to Claude Code",
            "Browser didn't open? Use the url below to sign in",
            "Paste code here if prompted >",
        ] {
            assert!(screen.contains(phrase), "missing {phrase:?} in:\n{screen}");
        }
    }
}
