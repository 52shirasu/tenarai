import KanaKanjiConverterModule

/// Text typed after Shift+letter is Latin, so symbols stay as typed: "Ab!" rather than
/// "Ab！". Japanese keys carry the full-width form as their intention.
public enum LatinCompositionInput {
    public static func typed(_ pieces: [InputPiece]) -> [InputPiece] {
        pieces.map { piece in
            if case .key(_, let input, _) = piece {
                return .character(input)
            }
            return piece
        }
    }
}
