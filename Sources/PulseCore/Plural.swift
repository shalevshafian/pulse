/// "1 day", "3 days".
public enum Plural {
    public static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }
}
