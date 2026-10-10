import Foundation

@main struct Tests {
    static func main() throws {
        var budget = AudioBudget()
        budget.record(bytes: 48000 * 60)
        precondition(budget.remaining == nil)
        precondition(abs(budget.spent - 0.034) < 0.0000001)
        precondition(budget.setRemaining("9,99"))
        for _ in 0..<100 { budget.record(bytes: 480) }
        precondition(abs(budget.remaining! - (9.99 - 0.034 / 60)) < 0.0000001)
        let spent = budget.spent
        for invalid in ["nan", "inf", "-1", "", "wrong"] { precondition(!budget.setRemaining(invalid)) }
        precondition(budget.setRemaining("10"))
        precondition(budget.spent == spent && abs(budget.seconds - 61) < 0.000001)
        let copy = try JSONDecoder().decode(AudioBudget.self, from: JSONEncoder().encode(budget))
        precondition(copy.remaining == budget.remaining && copy.spent == budget.spent)
        budget.record(bytes: 0)
        precondition(budget.spent == spent)
        print("PASS audio budget: partial submissions, manual balance, validation, persistence")
    }
}
