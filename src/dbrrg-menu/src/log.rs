//! The log under the grid: what the menu did, and what the programs it
//! started wrote. Tiles come from files the user writes, so their output is
//! untrusted: every line is cut at `LINE_BYTES`, and the log, the queue
//! between the reader threads and the event loop, and the splitter's buffer
//! all have a fixed ceiling.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};

/// Lines the log keeps, and the most the queue holds before the oldest go.
pub const LOG_LINES: usize = 500;
/// The longest line kept, in bytes of program output. A longer one is cut
/// and ends in "…"; the rest of it up to its newline is dropped.
pub const LINE_BYTES: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    /// Something the menu did: a start, a clean exit, a save.
    Event,
    /// A line a program wrote.
    Output,
    /// A failure, or a warning about the tile files.
    Warn,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    /// Local wall-clock time, HH:MM:SS.
    pub time: String,
    /// The tile name for program output, `None` for the menu's own lines.
    pub source: Option<String>,
    pub text: String,
    pub kind: Kind,
}

#[derive(Debug, Default)]
pub struct Log {
    lines: VecDeque<Line>,
}

impl Log {
    /// Add a line, dropping the oldest past `LOG_LINES`. Every line also goes
    /// to stderr, which dbrrg-session sends to the session log: before the
    /// log existed, program output went there directly.
    pub fn push(&mut self, line: Line) {
        match &line.source {
            Some(s) => eprintln!("dbrrg-menu: {s} | {}", line.text),
            None => eprintln!("dbrrg-menu: {}", line.text),
        }
        if self.lines.len() == LOG_LINES {
            self.lines.pop_front();
        }
        self.lines.push_back(line);
    }

    /// A line of the menu's own, stamped now.
    pub fn note(&mut self, kind: Kind, text: impl Into<String>) {
        self.push(Line {
            time: local_time(),
            source: None,
            text: text.into(),
            kind,
        });
    }

    pub fn lines(&self) -> impl ExactSizeIterator<Item = &Line> {
        self.lines.iter()
    }

    pub fn last(&self) -> Option<&Line> {
        self.lines.back()
    }
}

/// The local time of day, HH:MM:SS.
pub fn local_time() -> String {
    // SAFETY: time(NULL) has no preconditions; localtime_r writes only into
    // the struct passed to it, and a failure leaves it zeroed.
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
    }
}

/// Program output as one printable line: invalid UTF-8 replaced, a tab as a
/// space, other control characters (terminal escapes, a stray CR) removed.
pub fn clean(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .chars()
        .filter_map(|c| match c {
            '\t' => Some(' '),
            c if c.is_control() => None,
            c => Some(c),
        })
        .collect()
}

/// Splits a byte stream into lines without ever holding more than
/// `LINE_BYTES` of it.
#[derive(Debug, Default)]
pub struct Splitter {
    buf: Vec<u8>,
    /// The current line was already cut; drop the rest of it.
    skipping: bool,
}

impl Splitter {
    pub fn feed(&mut self, mut chunk: &[u8], out: &mut impl FnMut(String)) {
        while !chunk.is_empty() {
            let nl = chunk.iter().position(|&b| b == b'\n');
            let (part, rest, ends) = match nl {
                Some(i) => (&chunk[..i], &chunk[i + 1..], true),
                None => (chunk, &chunk[chunk.len()..], false),
            };
            if !self.skipping {
                let room = LINE_BYTES - self.buf.len();
                if part.len() > room {
                    self.buf.extend_from_slice(&part[..room]);
                    out(format!("{}…", clean(&self.buf)));
                    self.buf.clear();
                    self.skipping = true;
                } else {
                    self.buf.extend_from_slice(part);
                }
            }
            if ends {
                if !self.skipping {
                    out(clean(&self.buf));
                }
                self.buf.clear();
                self.skipping = false;
            }
            chunk = rest;
        }
    }

    /// The stream ended: a last line without a newline is still a line.
    pub fn finish(&mut self, out: &mut impl FnMut(String)) {
        if !self.skipping && !self.buf.is_empty() {
            out(clean(&self.buf));
        }
        self.buf.clear();
        self.skipping = false;
    }
}

/// Lines on their way from the reader threads to the event loop. The loop
/// may be slower than a program that floods its output, so the queue drops
/// its oldest lines rather than grow.
#[derive(Debug, Default)]
pub struct Feed {
    queue: Mutex<VecDeque<Line>>,
    ready: Condvar,
}

impl Feed {
    pub fn push(&self, line: Line) {
        let mut q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        if q.len() == LOG_LINES {
            q.pop_front();
        }
        q.push_back(line);
        self.ready.notify_one();
    }

    pub fn drain(&self) -> Vec<Line> {
        let mut q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        q.drain(..).collect()
    }

    /// Block until at least one line is queued.
    pub fn wait(&self) {
        let mut q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        while q.is_empty() {
            q = self.ready.wait(q).unwrap_or_else(|e| e.into_inner());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split(chunks: &[&[u8]]) -> Vec<String> {
        let mut s = Splitter::default();
        let mut out = Vec::new();
        for c in chunks {
            s.feed(c, &mut |l| out.push(l));
        }
        s.finish(&mut |l| out.push(l));
        out
    }

    #[test]
    fn lines_split_across_chunks_are_joined() {
        assert_eq!(split(&[b"one\ntw", b"o\nthree"]), ["one", "two", "three"]);
        assert_eq!(split(&[b"\n\n"]), ["", ""]);
    }

    #[test]
    fn a_long_line_is_cut_and_its_rest_dropped() {
        let long = vec![b'x'; LINE_BYTES * 3];
        let out = split(&[&long[..1000], &long[1000..], b"\nnext\n"]);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], format!("{}…", "x".repeat(LINE_BYTES)));
        assert_eq!(out[1], "next");
    }

    #[test]
    fn a_line_of_exactly_the_limit_is_not_cut() {
        let mut exact = vec![b'y'; LINE_BYTES];
        exact.push(b'\n');
        assert_eq!(split(&[&exact]), ["y".repeat(LINE_BYTES)]);
    }

    #[test]
    fn an_endless_line_holds_at_most_the_limit() {
        let mut s = Splitter::default();
        let mut n = 0;
        let chunk = vec![b'z'; 4096];
        for _ in 0..1000 {
            s.feed(&chunk, &mut |_| n += 1);
            assert!(s.buf.len() <= LINE_BYTES);
        }
        assert_eq!(n, 1, "cut once, the rest dropped");
    }

    #[test]
    fn control_characters_are_removed() {
        assert_eq!(clean(b"\x1b[31mred\x1b[0m\r"), "[31mred[0m");
        assert_eq!(clean(b"a\tb"), "a b");
        assert_eq!(clean(b"bad \xff byte"), "bad \u{fffd} byte");
    }

    fn line(text: &str) -> Line {
        Line {
            time: "12:00:00".into(),
            source: Some("T".into()),
            text: text.into(),
            kind: Kind::Output,
        }
    }

    #[test]
    fn the_log_keeps_the_newest_lines() {
        let mut log = Log::default();
        for i in 0..LOG_LINES + 10 {
            log.push(line(&i.to_string()));
        }
        assert_eq!(log.lines().len(), LOG_LINES);
        assert_eq!(log.lines().next().unwrap().text, "10");
        assert_eq!(log.last().unwrap().text, (LOG_LINES + 9).to_string());
    }

    #[test]
    fn the_feed_drops_its_oldest_lines_when_full() {
        let feed = Feed::default();
        for i in 0..LOG_LINES * 3 {
            feed.push(line(&i.to_string()));
        }
        let got = feed.drain();
        assert_eq!(got.len(), LOG_LINES);
        assert_eq!(got[0].text, (LOG_LINES * 2).to_string());
        assert!(feed.drain().is_empty());
    }

    #[test]
    fn local_time_is_hh_mm_ss() {
        let t = local_time();
        assert_eq!(t.len(), 8, "{t}");
        assert!(
            t.chars()
                .enumerate()
                .all(|(i, c)| if i == 2 || i == 5 { c == ':' } else { c.is_ascii_digit() })
        );
    }
}
