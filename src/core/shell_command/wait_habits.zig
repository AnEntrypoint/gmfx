const std = @import("std");

pub const sleep_poll_note = "This command sleeps in a loop to poll. Start the work as a background task and wait once with WaitFor: task_id for a task, pid for another process, and a timeout sized to the expected run time.";
pub const repeated_status_note = "Repeated status calls cost a turn each. Wait once with WaitFor and a timeout sized to the expected run time.";

pub fn sleepsInPollLoop(command: []const u8) bool {
    const loops = hasWord(command, "while") or hasWord(command, "until") or hasWord(command, "for");
    return loops and hasWord(command, "sleep") and hasWord(command, "done");
}

fn hasWord(text: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, word)) |at| {
        const end = at + word.len;
        const starts_word = at == 0 or !isWordByte(text[at - 1]);
        const ends_word = end == text.len or !isWordByte(text[end]);
        if (starts_word and ends_word) return true;
        from = at + 1;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/';
}

test "a shell loop that sleeps between checks is a poll loop, and a plain sleep or a loop without sleep is not" {
    try std.testing.expect(sleepsInPollLoop("while ! test -f out.log; do sleep 5; done"));
    try std.testing.expect(sleepsInPollLoop("until curl -sf localhost:3000; do\n  sleep 1\ndone"));
    try std.testing.expect(sleepsInPollLoop("for i in 1 2 3; do pgrep zig || break; sleep 15; done; echo over"));
    try std.testing.expect(!sleepsInPollLoop("sleep 2 && echo ready"));
    try std.testing.expect(!sleepsInPollLoop("for f in *.zig; do wc -l \"$f\"; done"));
    try std.testing.expect(!sleepsInPollLoop("while read line; do echo \"$line\"; done < list.txt"));
    try std.testing.expect(!sleepsInPollLoop("./sleep-test.sh; echo done-marker; whiled"));
    try std.testing.expect(!sleepsInPollLoop(""));
}
