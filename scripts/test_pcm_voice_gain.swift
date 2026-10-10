import Foundation

@main struct Tests {
    static func pcm(_ values: [Int16]) -> Data {
        Data(values.flatMap { value -> [UInt8] in
            let bits = UInt16(bitPattern: value)
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        })
    }
    static func samples(_ data: Data) -> [Int16] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }
    static func main() {
        let quiet = pcm((0..<4800).map { $0 % 2 == 0 ? 180 : -180 })
        var gain = PCMVoiceGain()
        let amplified = gain.process(quiet, enabled: true)
        precondition(amplified.count == quiet.count)
        let values = samples(amplified)
        precondition(values.last == -1440 && values[1000] == 1440)
        precondition(gain.maximumGain == 8)
        precondition(zip(values, samples(quiet)).allSatisfy { pair in (pair.0 >= 0) == (pair.1 >= 0) })
        let silence = pcm(Array(repeating: 0, count: 4800))
        precondition(gain.process(silence, enabled: true) == silence)
        let floor = pcm(Array(repeating: 4, count: 4800))
        precondition(gain.process(floor, enabled: true) == floor)
        let loud = pcm([32767, -32768] + Array(repeating: 300, count: 4798))
        precondition(gain.process(loud, enabled: true) == loud)
        precondition(gain.process(quiet, enabled: false) == quiet)
        var capped = PCMVoiceGain()
        let spike = pcm([20000] + Array(repeating: 300, count: 4799))
        let limited = samples(capped.process(spike, enabled: true))
        precondition(limited.map { abs(Int($0)) }.max()! <= 27853)
        print("PASS voice gain: quiet speech, no clipping, silence/noise floor, exact duration/sign, bypass")
    }
}
