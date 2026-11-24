/// Tuning shared by every converter in the process; set once at startup.
public enum ZenzaiTuning {
    /// After the model rejects a candidate containing a learned or user-dictionary word,
    /// make those words obey the model's prefix constraint for the rest of that request.
    /// Off restores the upstream behaviour (isolated comparisons only).
    public nonisolated(unsafe) static var constrainsRejectedPersonalWords = true
}
