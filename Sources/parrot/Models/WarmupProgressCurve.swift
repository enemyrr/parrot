/// Folds a sawtooth of per-sub-operation fractions into one that only climbs.
///
/// FluidAudio reports progress per sub-operation — a separate reporter per
/// CoreML model — so the raw fraction runs 0→1 once per model, four times on a
/// cached start. Fed straight to a progress bar, a download that is working
/// looks like it is looping.
///
/// Each sub-operation is given half of whatever progress is left — 0→50%,
/// 50→75%, 75→87.5% — so the curve needs no advance knowledge of how many are
/// coming, never regresses, and never reaches 100% on its own. The caller owns
/// the landing on 1.0.
struct WarmupProgressCurve {
    private var segmentStart: Double = 0
    private var segmentSpan: Double = 0.5
    private var lastRaw: Double = 0

    /// Feed the next raw fraction; a value below the previous one is read as
    /// "a new sub-operation started".
    mutating func advance(to raw: Double) -> Double {
        // Clamped before the comparison, not just before the multiply: an
        // out-of-range report stored raw would make the next ordinary value
        // look like a regression and burn a segment on nothing.
        let clamped = min(max(raw, 0), 1)
        if clamped < lastRaw {
            segmentStart += segmentSpan
            segmentSpan /= 2
        }
        lastRaw = clamped
        return segmentStart + segmentSpan * clamped
    }
}
