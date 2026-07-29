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
//! So the token is reassembled from its OWN rows: consecutive rows made only of token
//! characters, terminated by the blank row that claude's `gap:1` panel always leaves
//! after it. The single inferred width still does the prose, and no longer decides the
//! credential.
//!
//! Taking the width from `ioctl(TIOCGWINSZ)` was the obvious alternative and is worse:
//! it assumes how `script(1)` sizes the child pty, which differs between BSD and
//! util-linux, and it cannot be exercised by a unit test.

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

/// The exact length of a `sk-ant-oat…` setup token, in characters.
///
/// An observed invariant of the vendor, not a contract: every setup token claude has
/// minted here has been exactly 108 characters (live captures on 2026-07-26 and -28,
/// the report on issue #5, docs/ONBOARDING.md), and the fixture below asserts it. The
/// length is what makes a stale repaint cell separable from the credential it sits
/// against: exactly this many token characters followed by anything outside the token
/// alphabet is the token plus debris, and an unbroken run of any other length is
/// nothing nameable. If claude ever changes its token length, capture refuses with
/// both numbers in the message rather than guessing where the token ends — change this
/// constant and the fixture together. `ceremonies` also pins the setup-token pty to
/// exactly this many columns, which is what makes the debris case unreachable there.
pub(crate) const SETUP_TOKEN_LENGTH: usize = 108;

/// What the replayed screen holds where a token should be.
///
/// One reading, shared by `capture_setup_token`, `capture_note`, and `refusal_reason`,
/// so the capture and the explanation can never describe two different screens.
enum Reading {
    /// Exactly [`SETUP_TOKEN_LENGTH`] token characters, with whatever a repaint left
    /// beside them set aside — `discarded` names those cells when there were any.
    Token {
        token: String,
        discarded: Option<String>,
    },
    /// No line on the screen begins `sk-ant-oat` at all.
    Absent { lines: usize },
    /// An unbroken token-alphabet run of the wrong length. One character over is the
    /// dangerous shape: a stale cell that happens to sit in the token alphabet, fused
    /// to the token with nothing to mark the seam.
    WrongLength { length: usize },
    /// The candidate line left the token alphabet before reaching full length, so it
    /// carries something that is not the credential inside the token's own columns.
    Broken { run: usize, length: usize },
    /// Token-alphabet rows ran straight into other text with no blank row between,
    /// where claude's `gap:1` panel always leaves one — the reconstruction cannot be
    /// trusted end to end.
    Ungapped { length: usize },
}

/// Read the token off the replayed lines, length-aware.
///
/// The token starts a displayed line — claude renders it as its own Text node — but the
/// line is NOT required to be the token alone, because the TUI repaints without erase
/// sequences and a prior frame's cells past the new content can survive on the token's
/// row (issue #5: a 108-char token at 110 columns came back as a 109-char line, one
/// stale cell fused to it). The token alphabet plus the fixed length decide instead:
///
///   - exactly [`SETUP_TOKEN_LENGTH`] token characters, then a character OUTSIDE the
///     alphabet: the token, plus stale cells — extract the token, set the debris aside;
///   - a longer unbroken run: a stale cell INSIDE the alphabet, indistinguishable from
///     the credential — refuse, never guess where the token ends;
///   - a shorter run against a longer line, or rows that end without the `gap:1` blank
///     row: a reconstruction that cannot be trusted — refuse.
///
/// ONE CASE RESTS ON AN OBSERVED PROPERTY OF THE VENDOR BINARY, not on a contract. A
/// token exactly as wide as the terminal is indistinguishable, in a transcript, from one
/// that wrapped: both are a full-width row followed by another row. What separates them
/// is that claude's token panel carries `gap:1`, so a blank row always follows the token
/// and rejoining a full-width row with a blank one changes nothing. That was read out of
/// the claude 2.1.220 bundle and confirmed against a live capture on 2026-07-27.
/// CLAUDE.md's standing warning applies: harness CLIs update underneath us. If a future
/// claude drops that gap, this case stops being decidable — and it then fails CLOSED,
/// with `refusal_reason` saying exactly that, rather than welding the next line onto the
/// token.
fn read_token(lines: &[String]) -> Reading {
    let Some(start) = lines
        .iter()
        .rposition(|line| line.trim().starts_with("sk-ant-oat"))
    else {
        return Reading::Absent { lines: lines.len() };
    };
    let line = lines[start].trim();
    let run = line
        .chars()
        .take_while(|character| is_token_character(*character))
        .count();
    let length = line.chars().count();

    if run < length {
        // The line leaves the token alphabet somewhere. The alphabet boundary decides
        // which side of it the credential is on.
        return if run == SETUP_TOKEN_LENGTH {
            Reading::Token {
                token: line.chars().take(SETUP_TOKEN_LENGTH).collect(),
                discarded: Some(line.chars().skip(SETUP_TOKEN_LENGTH).collect()),
            }
        } else if run > SETUP_TOKEN_LENGTH {
            Reading::WrongLength { length: run }
        } else {
            Reading::Broken { run, length }
        };
    }

    // A pure token-alphabet line: the token itself, possibly wrapped across rows.
    // `displayed_lines` rejoins on ONE width -- the widest row anywhere -- so it only
    // reunites the token when the token wrapped at that same width. When the panel
    // wraps narrower than the widest row on screen, the token's first row is short of
    // that width, no rejoin happens, and the orphaned first row is ITSELF a well-formed
    // bare prefix. Continuing across adjacent token-character rows closes that: they
    // are the remainder, and gap:1 means nothing else is ever adjacent.
    let mut end = start;
    while lines
        .get(end + 1)
        .is_some_and(|line| is_token_run(line.trim()))
    {
        end += 1;
    }
    let assembled: String = lines[start..=end].iter().map(|line| line.trim()).collect();
    let assembled_length = assembled.chars().count();

    // gap:1 as a COMPLETENESS check: a whole token is always followed by a blank row,
    // or by the end of the screen.
    match lines.get(end + 1) {
        None => {}
        Some(next) if next.trim().is_empty() => {}
        Some(_) => {
            return Reading::Ungapped {
                length: assembled_length,
            };
        }
    }

    if assembled_length == SETUP_TOKEN_LENGTH {
        Reading::Token {
            token: assembled,
            discarded: None,
        }
    } else {
        Reading::WrongLength {
            length: assembled_length,
        }
    }
}

/// The `sk-ant-oat…` token the TUI displayed, or None if it never displayed one whole.
///
/// Refusing on anything unexplained is the point: a captured token that is wrong by one
/// character banks successfully and fails later as an auth error nobody traces back
/// here, so an ambiguous screen has to fail loudly instead of being mined for something
/// token-shaped.
pub fn capture_setup_token(transcript: &[u8]) -> Option<String> {
    match read_token(&displayed_lines(transcript)) {
        Reading::Token { token, .. } => Some(token),
        _ => None,
    }
}

/// What capture set aside on its way to the token, when it succeeded by discarding
/// stale cells — None when it discarded nothing (or refused). Surfaced to the operator
/// so a screen that needed interpreting is never interpreted silently.
pub fn capture_note(transcript: &[u8]) -> Option<String> {
    match read_token(&displayed_lines(transcript)) {
        Reading::Token {
            discarded: Some(cells),
            ..
        } => Some(format!(
            "the token's row carried {} stale cell(s) after the token ({cells:?}), left \
             there by an earlier frame that claude's repaint never cleared; they are \
             outside the token alphabet, so the {SETUP_TOKEN_LENGTH}-character token \
             before them was captured and they were discarded",
            cells.chars().count(),
        )),
        _ => None,
    }
}

/// Why capture refused, for the operator who has to act on it.
///
/// "not captured" on its own is what cost two single-use authorization codes: it named
/// neither what was searched for nor which situation had occurred. Each refusal names
/// its mechanism — and the stale-repaint refusals say so outright, because the cause
/// lives in claude's renderer, not in anything the operator did.
pub fn refusal_reason(transcript: &[u8]) -> String {
    match read_token(&displayed_lines(transcript)) {
        Reading::Token { .. } => "the token was captured; nothing was refused".to_owned(),
        Reading::Absent { lines } => {
            format!("no line of the {lines} line(s) on the replayed screen began with sk-ant-oat")
        }
        Reading::WrongLength { length } if length > SETUP_TOKEN_LENGTH => format!(
            "a line beginning sk-ant-oat was an unbroken run of {length} token-alphabet \
             characters, where a claude setup token is exactly {SETUP_TOKEN_LENGTH}. The \
             likeliest cause is a stale cell from an earlier frame surviving right after \
             the token — claude's TUI repaints without erasing, and a leftover cell that \
             happens to sit in the token alphabet cannot be told from the credential — \
             so this refuses rather than guessing which {} character(s) are not the \
             token. Re-running the ceremony lays the screen out afresh; if every run \
             refuses with this same arithmetic, claude has changed its token length and \
             SETUP_TOKEN_LENGTH needs updating",
            length - SETUP_TOKEN_LENGTH
        ),
        Reading::WrongLength { length } => format!(
            "a line beginning sk-ant-oat held only {length} token characters, where a \
             claude setup token is exactly {SETUP_TOKEN_LENGTH} — an incomplete \
             reconstruction, not a credential. Re-run the ceremony"
        ),
        Reading::Broken { run, length } => format!(
            "a line beginning sk-ant-oat was {length} characters long but left the token \
             alphabet after {run}, where a claude setup token is exactly \
             {SETUP_TOKEN_LENGTH} unbroken token characters — something that is not the \
             credential sits inside the token's own columns. Re-run the ceremony"
        ),
        Reading::Ungapped { length } => format!(
            "a line beginning sk-ant-oat was found ({length} token characters with its \
             adjacent rows), but it ran straight into other text with no blank row \
             between, where claude's token panel always leaves one — the reconstruction \
             cannot be trusted end to end. Re-run the ceremony"
        ),
    }
}

/// A row that could be the tail of a token split across rows: token characters and
/// nothing else. Blank is excluded — a blank row is the gap that ENDS the token.
fn is_token_run(line: &str) -> bool {
    !line.is_empty() && line.chars().all(is_token_character)
}

fn is_token_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A FABRICATED token. Not derived from any real credential, and self-evidently so:
    /// it says what it is, and the tail is a repeating digit run.
    ///
    /// Only two things about it are real, and both are public: the `sk-ant-oat01-` prefix,
    /// and the LENGTH. 108 characters is what claude issues, and the length is what the
    /// tests turn on -- the whole defect is about characters going missing, so a fixture
    /// of the wrong length would exercise wrapping at the wrong boundaries and could pass
    /// while the real thing failed. If claude's token length ever changes, change this and
    /// keep it exact.
    const TOKEN: &str = "sk-ant-oat01-SYNTHETIC-FIXTURE-NOT-A-REAL-TOKEN-012345678901234567890123456789012345678901234567890123456789";

    /// The length is load-bearing, so it is asserted rather than trusted.
    #[test]
    fn the_fixture_token_is_the_length_claude_issues() {
        assert_eq!(TOKEN.chars().count(), SETUP_TOKEN_LENGTH);
        assert_eq!(SETUP_TOKEN_LENGTH, 108);
        assert!(TOKEN.starts_with("sk-ant-oat01-"));
        assert!(TOKEN.chars().all(is_token_character));
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

    #[test]
    fn token_survives_repaint_and_wrap_at_every_plausible_width() {
        let stale = stale_frame();
        for width in SWEEP_WIDTHS {
            let transcript = ceremony_transcript(width, Erase::PadsToWidth, &stale);
            assert!(
                !transcript.contains(TOKEN),
                "width {width}: the transcript must not contain the token contiguously"
            );
            assert_eq!(
                capture_setup_token(transcript.as_bytes()),
                Some(TOKEN.to_owned()),
                "width {width}"
            );
        }
    }

    /// The same sweep under the no-erase renderer. Under it, capture cannot promise
    /// the exact token at every width -- a stale cell that lands in the token alphabet
    /// is indistinguishable from the credential, and refusing IS the correct outcome
    /// -- so the property here is safety: every width yields either the exact token or
    /// a refusal that explains itself. No width may ever yield wrong bytes, which is
    /// the failure worth more than all the others (it banks, then 401s a month later).
    #[test]
    fn under_repaint_without_erase_no_width_yields_a_wrong_token() {
        let stale = stale_frame();
        for width in SWEEP_WIDTHS {
            let transcript = ceremony_transcript(width, Erase::LeavesStaleCells, &stale);
            match capture_setup_token(transcript.as_bytes()) {
                Some(token) => assert_eq!(token, TOKEN, "width {width}: wrong bytes captured"),
                None => {
                    let reason = refusal_reason(transcript.as_bytes());
                    assert!(
                        reason.contains("Re-run") || reason.contains("no line"),
                        "width {width}: refusal must explain itself: {reason}"
                    );
                }
            }
        }
    }

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
    /// plus one stale non-token cell at column 109. The token is extracted and the
    /// stale cell is named, not silently eaten.
    #[test]
    fn issue_5_a_stale_cell_after_the_token_is_discarded_and_named() {
        let stale = format!("{}%", "#".repeat(108)); // 109 wide; column 109 holds '%'
        let screen = issue_5_screen(110, &stale);

        let lines = displayed_lines(screen.as_bytes());
        assert!(
            lines
                .iter()
                .any(|line| line.trim().starts_with("sk-ant-oat") && line.chars().count() == 109),
            "fixture must reproduce the 109-char token line; lines {lines:?}"
        );

        assert_eq!(
            capture_setup_token(screen.as_bytes()).as_deref(),
            Some(TOKEN),
            "issue-5 geometry must capture; refusal was: {}",
            refusal_reason(screen.as_bytes())
        );
        let note = capture_note(screen.as_bytes()).expect("the stale cell must be named");
        assert!(note.contains("1 stale cell"), "{note}");
        assert!(note.contains('%'), "{note}");
    }

    /// Boundaries around the reported geometry: the stale tail makes the token line
    /// exactly the terminal width (so it rejoins as a full-width row), at 110 and 109
    /// columns, and one past the width (so one stale cell wraps to the next row and
    /// the rejoin welds it back). All must extract the exact token.
    #[test]
    fn issue_5_boundaries_extract_the_exact_token() {
        for (width, stale_tail) in [(110usize, 2usize), (109, 1), (110, 3)] {
            let stale = format!("{}{}", "#".repeat(108), "%".repeat(stale_tail));
            let screen = issue_5_screen(width, &stale);
            assert_eq!(
                capture_setup_token(screen.as_bytes()).as_deref(),
                Some(TOKEN),
                "width {width}, stale tail {stale_tail}: {}",
                refusal_reason(screen.as_bytes())
            );
        }
    }

    /// Issue #5's flagged near-miss: the stale cell holds a token-ALPHABET character,
    /// so the 109-char line is an unbroken run and nothing marks where the token ends.
    /// Capturing 109 bytes here is the wrong-token hazard; the length gate refuses and
    /// the refusal does the arithmetic and names the stale-repaint cause.
    #[test]
    fn issue_5_near_miss_in_the_token_alphabet_refuses_with_the_arithmetic() {
        let stale = format!("{}Z", "#".repeat(108)); // column 109 holds 'Z'
        let screen = issue_5_screen(110, &stale);
        assert_eq!(
            capture_setup_token(screen.as_bytes()),
            None,
            "an unbroken 109-char run must never be banked as a token"
        );
        let reason = refusal_reason(screen.as_bytes());
        assert!(reason.contains("109"), "{reason}");
        assert!(reason.contains("exactly 108"), "{reason}");
        assert!(reason.contains("stale cell"), "{reason}");
    }

    /// Control: the same layout with NO stale tail, at the boundary widths -- shows
    /// the assertions above are about the stale cell, not the widths.
    #[test]
    fn issue_5_control_clean_token_at_boundary_widths() {
        for width in [107usize, 108, 109, 110, 111] {
            let screen = issue_5_screen(width, &stale_frame());
            assert_eq!(
                capture_setup_token(screen.as_bytes()).as_deref(),
                Some(TOKEN),
                "clean control failed at width {width}: {}",
                refusal_reason(screen.as_bytes())
            );
        }
    }

    /// The ceremony pins its pty at exactly [`SETUP_TOKEN_LENGTH`] columns (see
    /// `ceremonies::script_args`). At that width the issue-#5 mechanism is unreachable
    /// even under the no-erase renderer: no row can be wider than the token, so no
    /// stale cell can survive past its end -- the token's repaint covers its row edge
    /// to edge. A full row of token-alphabet junk under the token, the worst stale
    /// content there is, must still yield a clean exact capture with nothing to
    /// discard.
    #[test]
    fn at_the_pinned_width_the_token_row_cannot_carry_stale_cells() {
        let stale = "Z".repeat(SETUP_TOKEN_LENGTH);
        let screen = issue_5_screen(SETUP_TOKEN_LENGTH, &stale);
        assert_eq!(
            capture_setup_token(screen.as_bytes()).as_deref(),
            Some(TOKEN),
            "{}",
            refusal_reason(screen.as_bytes())
        );
        assert_eq!(
            capture_note(screen.as_bytes()),
            None,
            "nothing may need discarding at the pinned width"
        );
    }

    /// The pinned width protects the token's ROW; it cannot promise the rest of the
    /// screen. If a no-erase repaint ever leaves token-alphabet junk standing on the
    /// gap row BELOW the token, the reconstruction is undecidable and must refuse --
    /// safely, never by extending the token.
    #[test]
    fn stale_content_on_the_gap_row_refuses_rather_than_extending_the_token() {
        let label = "Your OAuth token (valid for 1 year):";
        let mut tui = Tui::without_erase(SETUP_TOKEN_LENGTH);
        tui.render(&[label, "", &stale_frame(), "0123456789abcdef"])
            .render(&[label, "", TOKEN, ""]);
        assert_eq!(
            capture_setup_token(tui.transcript().as_bytes()),
            None,
            "junk on the gap row must refuse, not weld onto the token"
        );
        let reason = refusal_reason(tui.transcript().as_bytes());
        assert!(reason.contains("Re-run"), "{reason}");
    }

    /// The shape reported from shrdlu: characters inside the token were never emitted,
    /// because the frame underneath already held the same character at those columns.
    /// Column 7 falls inside `sk-ant-oat`, so even the prefix arrives broken.
    #[test]
    fn the_observed_skipped_cells_are_recovered_not_dropped() {
        let characters: Vec<char> = TOKEN.chars().collect();
        let already_right = [7usize, 15];
        let stale: String = (0..characters.len())
            .map(|column| {
                if already_right.contains(&column) {
                    characters[column]
                } else {
                    'Z'
                }
            })
            .collect();
        assert_eq!(characters[7], 'o', "column 7 must sit inside sk-ant-oat");

        let mut tui = Tui::new(characters.len());
        tui.render(&[&stale]);
        let before = tui.transcript().len();
        tui.render(&[TOKEN]);

        assert!(
            !tui.transcript()[before..].contains("sk-ant-oat"),
            "the repaint must not emit the prefix contiguously"
        );
        assert_eq!(
            capture_setup_token(tui.transcript().as_bytes()),
            Some(TOKEN.to_owned())
        );
    }

    /// A shorter frame painted over a longer one WITHOUT clearing the tail: the
    /// leftover cells sit on the token's row and the rejoin welds them onto it. The
    /// welded tail here leaves the token alphabet immediately (`/` at the seam), so the
    /// length gate can name the boundary: exactly [`SETUP_TOKEN_LENGTH`] token
    /// characters, then debris — the token is extracted, the debris is discarded, and
    /// `capture_note` says so out loud. Issue #5 is this exact shape in the wild.
    #[test]
    fn an_uncleared_tail_outside_the_alphabet_is_discarded_legibly() {
        let width = 40;
        let previous: String = URL.chars().take(width).collect();
        let mut screen = String::new();
        for chunk in TOKEN
            .chars()
            .collect::<Vec<_>>()
            .chunks(width)
            .map(|chunk| chunk.iter().collect::<String>())
        {
            // Whatever the new row does not cover still shows the old frame.
            let uncovered: String = previous.chars().skip(chunk.chars().count()).collect();
            screen.push_str(&format!("{chunk}{uncovered}\r\n"));
        }

        // Every row is exactly full width, so the rejoin welds URL text onto the end of
        // the token; the seam character must be outside the token alphabet for this to
        // be the extractable case rather than the refusable one.
        let rejoined = displayed_lines(screen.as_bytes());
        assert!(
            rejoined
                .iter()
                .any(|line| line.starts_with(TOKEN) && line.chars().count() > TOKEN.chars().count()),
            "the fixture must actually weld a tail onto the token, got {rejoined:?}"
        );

        assert_eq!(
            capture_setup_token(screen.as_bytes()).as_deref(),
            Some(TOKEN)
        );
        let note = capture_note(screen.as_bytes()).expect("discarded cells must be named");
        assert!(note.contains("stale cell"), "{note}");
        assert!(note.contains("discarded"), "{note}");
    }

    /// The two corruptions at once, stated rather than stumbled into: the wrap boundary
    /// falls INSIDE the `sk-ant-oat` prefix, and cells inside that prefix were skipped by
    /// the repaint because the frame underneath already held the same characters. Neither
    /// half is recoverable from the bytes alone; both are recoverable from the screen.
    #[test]
    fn a_split_inside_the_prefix_with_skipped_cells_inside_it_too() {
        let width = 5;
        let stale = stale_frame();

        // Columns 0 and 8 of the token survive into the stale frame, and both sit inside
        // the prefix -- so the repaint never emits them, and the split at column 5 lands
        // between them.
        assert_eq!(stale.chars().next(), TOKEN.chars().next());
        assert_eq!(stale.chars().nth(8), TOKEN.chars().nth(8));

        let mut tui = Tui::new(width);
        tui.render(&["Your OAuth token (valid for 1 year):", "", &stale])
            .render(&["Your OAuth token (valid for 1 year):", "", TOKEN]);

        let transcript = tui.transcript();
        assert!(
            !transcript.contains("sk-ant-oat"),
            "the prefix must not appear contiguously anywhere in the transcript"
        );
        assert!(
            !transcript.contains("sk-an"),
            "not even the fragment before the split"
        );
        assert_eq!(
            capture_setup_token(transcript.as_bytes()),
            Some(TOKEN.to_owned())
        );
    }

    /// A token displayed plainly, with no repaint and no wrapping -- the shape the old
    /// whitespace scan handled, kept so the fix is not narrower than what it replaces.
    /// The token is the full-length fixture: capture is length-gated, so a token-shaped
    /// string of any other length is not a token.
    #[test]
    fn captures_the_non_rotating_claude_setup_token() {
        let plain = format!("browser output\n{TOKEN}\r\n");
        assert_eq!(
            capture_setup_token(plain.as_bytes()),
            Some(TOKEN.to_owned())
        );
        assert_eq!(capture_setup_token(b"no token here"), None);
    }

    /// The length gate itself: a plausible `sk-ant-oat…` line of the WRONG length is
    /// refused, and the refusal does the arithmetic for the operator.
    #[test]
    fn a_token_shaped_run_of_the_wrong_length_is_refused_with_both_numbers() {
        let short = b"sk-ant-oat01-example\r\n";
        assert_eq!(capture_setup_token(short), None);
        let reason = refusal_reason(short);
        assert!(reason.contains("only 20 token characters"), "{reason}");
        assert!(reason.contains("exactly 108"), "{reason}");
    }

    /// An OSC 8 hyperlink's payload must be consumed as an escape, never printed. The
    /// real transcript wraps the OAuth URL in one, and its PKCE blob is made of exactly
    /// the characters a token is made of -- printed into the screen it would corrupt the
    /// row the token is read from. This is the case that decided the `vte` dependency.
    #[test]
    fn a_hyperlink_payload_never_reaches_the_screen() {
        let transcript =
            format!("\x1b]8;id=7655xh;{URL}\x07visible text\x1b]8;;\x07\r\n{TOKEN}\r\n");
        let lines = displayed_lines(transcript.as_bytes());
        assert_eq!(lines[0], "visible text");
        assert_eq!(
            capture_setup_token(transcript.as_bytes()),
            Some(TOKEN.to_owned())
        );
    }

    /// Invalid UTF-8 must not discard the transcript. `read_to_string` errored on it and
    /// `unwrap_or_default` turned that into an empty string, so one stray byte was
    /// indistinguishable from claude printing nothing at all.
    #[test]
    fn an_invalid_byte_does_not_discard_the_rest_of_the_screen() {
        let mut transcript = vec![0xff, b'\r', b'\n'];
        transcript.extend_from_slice(TOKEN.as_bytes());
        assert_eq!(capture_setup_token(&transcript), Some(TOKEN.to_owned()));
    }

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

    #[test]
    fn the_recorded_aborted_flow_yields_no_token() {
        assert_eq!(capture_setup_token(RECORDED), None);
        assert!(
            !String::from_utf8_lossy(RECORDED).contains("sk-ant"),
            "this fixture must never carry a credential"
        );
    }

    /// The obvious fix, and why it is not the one taken: strip every escape sequence,
    /// then match. It returns a token. The token is WRONG.
    ///
    /// This is the failure mode worth more than all the others put together, because it
    /// is the only one that succeeds: a well-formed token, short by exactly the cells the
    /// repaint skipped, which banks cleanly and surfaces days later as an unexplained
    /// auth failure with nothing pointing back at onboarding. Whether any cells get
    /// skipped is luck, which is why a capture that worked by hand proves nothing -- so
    /// here the coincidence is stated outright rather than waited for.
    ///
    /// If someone is about to simplify the screen replay into a regex, this is the test
    /// that should stop them.
    #[test]
    fn stripping_ansi_yields_a_silently_wrong_token() {
        fn strip_ansi_then_match(transcript: &str) -> Option<String> {
            let mut plain = String::new();
            let mut rest = transcript;
            while let Some(start) = rest.find('\x1b') {
                plain.push_str(&rest[..start]);
                let tail = &rest[start..];
                let end = tail
                    .char_indices()
                    .skip(1)
                    .find(|(_, character)| character.is_ascii_alphabetic())
                    .map(|(index, character)| index + character.len_utf8())
                    .unwrap_or(tail.len());
                rest = &tail[end..];
            }
            plain.push_str(rest);
            plain
                .split_whitespace()
                .rev()
                .find(|word| word.starts_with("sk-ant-oat"))
                .map(str::to_owned)
        }

        // Three cells of the token already held the right character, so the repaint
        // jumped over them and they were never emitted.
        let skipped = [17usize, 48, 91];
        let characters: Vec<char> = TOKEN.chars().collect();
        let stale: String = (0..characters.len())
            .map(|column| {
                if skipped.contains(&column) {
                    characters[column]
                } else {
                    ' '
                }
            })
            .collect();

        let mut tui = Tui::new(200);
        tui.render(&[&stale]).render(&[TOKEN]);
        let transcript = tui.transcript();

        let naive = strip_ansi_then_match(transcript).expect("the naive fix finds something");
        assert_ne!(
            naive, TOKEN,
            "stripping escapes was expected to produce the WRONG token"
        );
        assert!(
            naive.starts_with("sk-ant-oat01-"),
            "and wrong in the dangerous way -- still well-formed:\n  real  ({:>3}): {TOKEN}\n  naive ({:>3}): {naive}",
            TOKEN.chars().count(),
            naive.chars().count()
        );
        assert_eq!(
            naive.chars().count(),
            TOKEN.chars().count() - skipped.len(),
            "short by exactly the cells the repaint skipped:\n  real  ({:>3}): {TOKEN}\n  naive ({:>3}): {naive}",
            TOKEN.chars().count(),
            naive.chars().count()
        );

        // Same bytes, read off the screen instead.
        assert_eq!(
            capture_setup_token(transcript.as_bytes()),
            Some(TOKEN.to_owned()),
            "the screen replay must recover the real token from the same bytes"
        );
    }

    /// A refusal has to say which situation happened and name its mechanism. "not
    /// captured" alone is what cost two codes.
    #[test]
    fn a_refusal_says_why_it_refused() {
        let empty = refusal_reason(b"nothing token-shaped here\r\n");
        assert!(empty.contains("no line"), "{empty}");
        assert!(empty.contains("sk-ant-oat"), "{empty}");

        // One token-alphabet cell fused to the token: the near-miss. The refusal must
        // do the arithmetic and name the stale-repaint cause, not tell the operator to
        // resize a terminal the ceremony controls.
        let fused = refusal_reason(format!("{TOKEN}Z\r\n").as_bytes());
        assert!(fused.contains("109 token-alphabet characters"), "{fused}");
        assert!(fused.contains("exactly 108"), "{fused}");
        assert!(fused.contains("stale cell"), "{fused}");
        assert!(fused.contains("repaints without erasing"), "{fused}");

        // A non-token cell INSIDE the token's columns: the reconstruction is broken,
        // not merely dirty at the edge.
        let broken = refusal_reason(b"sk-ant-oat01-abc&def\r\n");
        assert!(
            broken.contains("left the token alphabet after 16"),
            "{broken}"
        );
        assert!(broken.contains("exactly 108"), "{broken}");
    }

    /// A screen that wraps at TWO widths, which is what a real headless ceremony renders.
    ///
    /// Measured on the failing run: the pty reported `stty size` = `0 0` with TERM unset,
    /// the TUI fell back to 80 columns, and the OAuth URL hard-wrapped at exactly 80. The
    /// token panel does not wrap at 80 — it wraps at its own narrower content width, so
    /// the token's first row is short of the widest row on screen and the width-based
    /// rejoin never fires.
    ///
    /// The assertion is the EXACT token, not a well-formed one. That distinction is the
    /// whole defect: what shipped banked a 79-character prefix that starts with
    /// `sk-ant-oat`, is made entirely of token characters, and is wrong. Every weaker
    /// assertion — starts_with, is_bare_token, "looks like a token" — passes on it.
    #[test]
    fn a_token_panel_narrower_than_the_widest_row_is_reassembled_whole() {
        // One column of difference is enough, and is the margin that actually bit.
        for content in [79usize, 76, 60, 40] {
            let mut screen = String::new();
            for chunk in URL.chars().collect::<Vec<_>>().chunks(80) {
                screen.push_str(&chunk.iter().collect::<String>());
                screen.push_str("\r\r\n");
            }
            screen.push_str("\r\r\n");
            for chunk in TOKEN.chars().collect::<Vec<_>>().chunks(content) {
                screen.push_str(&chunk.iter().collect::<String>());
                screen.push_str("\r\r\n");
            }
            // gap:1 — the blank row that says the token ended here.
            screen.push_str("\r\r\n");
            screen.push_str("Store this token securely.\r\r\n");

            let captured = capture_setup_token(screen.as_bytes());
            assert_eq!(captured.as_deref(), Some(TOKEN), "content width {content}");
            assert_eq!(
                captured.map(|token| token.chars().count()),
                Some(108),
                "content width {content}: a truncated token is well-formed, so the LENGTH \
                 is what has to be asserted"
            );
        }
    }

    /// The refusal has to fire on a screen that is genuinely undecidable. Tonight proved
    /// it can silently not fire: capture returned a truncated token, so nothing refused,
    /// no failure log was written, and a dead credential was banked as onboarded.
    #[test]
    fn an_ambiguous_screen_refuses_rather_than_banking_something_token_shaped() {
        // Token characters continue past the token with no gap row: the reconstruction
        // cannot say where the credential ended, so it must not guess.
        let welded = format!("{TOKEN}\r\n0123456789abcdef\r\nStore this token securely.\r\n");
        assert_eq!(capture_setup_token(welded.as_bytes()), None);

        // And the operator is told which situation it was.
        let reason = refusal_reason(welded.as_bytes());
        assert!(reason.contains("sk-ant-oat"), "{reason}");
        assert!(reason.contains("no blank row"), "{reason}");
        assert!(reason.contains("Re-run"), "{reason}");
    }
}
