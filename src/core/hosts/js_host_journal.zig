extern "fx" fn fx_journal_flush() i32;

pub fn flush() error{JournalFlushFailed}!void {
    if (fx_journal_flush() != 0) return error.JournalFlushFailed;
}
