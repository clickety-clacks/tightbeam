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
//! longest row the replay produced. That is exact in the only case where it matters,
//! and the argument is self-supporting. Nothing can be wider than the terminal, so the
//! longest row is never an over-estimate; and IF the token wrapped, then its own first
//! row is exactly the terminal width, so the token pins the width itself. The OAuth URL
//! (~250 characters, always displayed) usually pins it too, but nothing relies on that
//! — if a future claude stopped displaying the URL, this inference would not weaken.
//!
//! An under-estimate is the only dangerous direction, and it cannot happen while the
//! token wraps. If the token does NOT wrap, no rejoining occurs and the width is not
//! consulted for anything that matters.
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

/// The `sk-ant-oat…` token the TUI displayed, or None if it never displayed one.
///
/// The token must be the WHOLE displayed line, not a run found inside one. claude
/// renders it as its own Text node with nothing beside it, so anything else sharing
/// the line means the reconstruction is not what was displayed — a row rejoined that
/// should not have been, or a shorter frame painted over a longer one without clearing
/// the tail. Refusing there is the point: a captured token that is wrong by one
/// character banks successfully and fails later as an auth error nobody traces back
/// here, so an unexplained screen has to fail loudly instead of being mined for
/// something token-shaped.
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
pub fn capture_setup_token(transcript: &[u8]) -> Option<String> {
    displayed_lines(transcript)
        .iter()
        .rev()
        .map(|line| line.trim())
        .find(|line| is_bare_token(line))
        .map(str::to_owned)
}

/// Why capture refused, for the operator who has to act on it.
///
/// "not captured" on its own is what cost two single-use authorization codes: it named
/// neither what was searched for nor which of the two very different situations had
/// occurred. A screen with no token at all means claude never displayed one. A screen
/// whose token is not alone on its line means the reconstruction is ambiguous, which is
/// recoverable — the operator can re-run at a different terminal width.
pub fn refusal_reason(transcript: &[u8]) -> String {
    let lines = displayed_lines(transcript);
    let width = lines
        .iter()
        .map(|line| line.chars().count())
        .max()
        .unwrap_or(0);

    match lines
        .iter()
        .map(|line| line.trim())
        .find(|line| line.starts_with("sk-ant-oat"))
    {
        None => format!(
            "no line of the {} line(s) on the replayed screen began with sk-ant-oat",
            lines.len()
        ),
        Some(line) => format!(
            "a line beginning sk-ant-oat was found, but it was {} characters long and \
             carried more than the token, so it could not be told apart from a token that \
             wrapped across rows (widest row: {width} columns). Re-running in a terminal \
             of a different width will resolve it",
            line.chars().count()
        ),
    }
}

fn is_bare_token(line: &str) -> bool {
    line.starts_with("sk-ant-oat") && line.chars().all(is_token_character)
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
        assert_eq!(TOKEN.chars().count(), 108);
        assert!(TOKEN.starts_with("sk-ant-oat01-"));
        assert!(TOKEN.chars().all(is_token_character));
        assert!(
            TOKEN.contains("SYNTHETIC"),
            "this fixture must stay provably fabricated: it lives in a public repo"
        );
    }

    const URL: &str = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=Pc-oTIMUQocUA8wvn5TtJVCEDBZEzuNPuBGwxYh6ltk";

    /// A model of the claude TUI's renderer, as observed live at 2.1.220 on 2026-07-27.
    ///
    /// Five properties, and every one of them was got WRONG in an early draft of this
    /// fixture, in each case producing a test that passed while proving nothing. They are
    /// listed because a future reader tightening this model will otherwise re-break them:
    ///
    ///   1. REPAINT IS IN PLACE. A frame is diffed against what is already on those rows,
    ///      not written to fresh ones. Diffing against fresh rows loses the skipped cells
    ///      for real, so the test fails for the opposite of the reason it should.
    ///   2. NO ERASE SEQUENCES EXIST. Neither CSI K nor CSI J appears anywhere in a real
    ///      transcript, so the only way to clear a shrinking row is to write spaces over
    ///      its tail. A model that does not pad manufactures leftover characters that the
    ///      renderer never leaves.
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
        painted: Vec<String>,
        transcript: String,
    }

    impl Tui {
        fn new(width: usize) -> Self {
            Self {
                width,
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
            rows.resize(height, String::new());
            for row in &mut rows {
                while row.chars().count() < self.width {
                    row.push(' ');
                }
            }

            if !self.painted.is_empty() {
                self.transcript
                    .push_str(&format!("\r\x1b[{}A", self.painted.len()));
            }
            for index in 0..height {
                let was = self.painted.get(index).map(String::as_str).unwrap_or("");
                self.transcript.push_str(&repaint(was, &rows[index]));
                self.transcript.push_str("\r\r\n");
            }
            self.painted = rows;
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

    #[test]
    fn token_survives_repaint_and_wrap_at_every_plausible_width() {
        let stale = stale_frame();
        // Small widths split the token inside the `sk-ant-oat` prefix itself; 108 is the
        // token's exact length; above it nothing wraps at all.
        for width in [
            3usize, 5, 7, 9, 11, 13, 40, 60, 72, 80, 100, 107, 108, 109, 120, 200, 400,
        ] {
            // The panel claude 2.1.220 renders, blank lines included: its Box carries
            // gap:1, so every child is separated by an empty row. That blank row after the
            // token is what tells a token exactly as wide as the terminal apart from one
            // that wrapped -- without it the two are indistinguishable in a transcript.
            let label = "Your OAuth token (valid for 1 year):";
            let footer = "Store this token securely. You won't be able to see it again.";
            let mut tui = Tui::new(width);
            tui.render(&["Browser didn't open? Use the url below to sign in", "", URL])
                // The frame before the token lands, laid out the same way, so the stale
                // characters sit on the very rows the token is about to be painted over.
                .render(&[label, "", &stale, "", footer])
                .render(&[label, "", TOKEN, "", footer]);

            assert!(
                !tui.transcript().contains(TOKEN),
                "width {width}: the transcript must not contain the token contiguously"
            );
            assert_eq!(
                capture_setup_token(tui.transcript().as_bytes()),
                Some(TOKEN.to_owned()),
                "width {width}"
            );
        }
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

    /// The unsafe direction, pinned. If a shorter frame were ever painted over a longer
    /// one WITHOUT clearing the tail, the leftover characters would sit on the token's
    /// row, and a width-based rejoin would hand back the token with a tail glued to it.
    /// Capture must refuse instead.
    ///
    /// claude 2.1.220 does not do this -- it emits no erase sequences, so it can only
    /// clear a row by writing spaces, and the sweep above models that. This guards the
    /// rejoin rule against a renderer that stops padding, which would otherwise turn a
    /// wrapped token into a longer, well-formed, wrong one.
    #[test]
    fn an_uncleared_tail_refuses_instead_of_returning_a_longer_token() {
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

        // Every row is now exactly full width, so the rejoin welds URL text onto the end
        // of the token. That is the wrong answer this test exists to reject -- and it is
        // wrong in the dangerous way, being longer rather than malformed.
        let rejoined = displayed_lines(screen.as_bytes());
        assert!(
            rejoined
                .iter()
                .any(|line| line.starts_with(TOKEN) && line.chars().count() > TOKEN.chars().count()),
            "the fixture must actually weld a tail onto the token, got {rejoined:?}"
        );

        assert_eq!(
            capture_setup_token(screen.as_bytes()),
            None,
            "a token with an uncleared tail glued to it must not be captured"
        );
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
    #[test]
    fn captures_the_non_rotating_claude_setup_token() {
        assert_eq!(
            capture_setup_token(b"browser output\nsk-ant-oat01-example\r\n"),
            Some("sk-ant-oat01-example".to_owned())
        );
        assert_eq!(capture_setup_token(b"no token here"), None);
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

    /// A refusal has to say which of the two situations happened, and the ambiguous one
    /// has to say it is resolvable. "not captured" alone is what cost two codes.
    #[test]
    fn a_refusal_says_why_it_refused() {
        let empty = refusal_reason(b"nothing token-shaped here\r\n");
        assert!(empty.contains("no line"), "{empty}");
        assert!(empty.contains("sk-ant-oat"), "{empty}");

        let welded = refusal_reason(format!("{TOKEN}&code_challenge=Pc\r\n").as_bytes());
        assert!(welded.contains("carried more than the token"), "{welded}");
        assert!(welded.contains("wrapped across rows"), "{welded}");
        assert!(welded.contains("different width"), "{welded}");
    }
}
