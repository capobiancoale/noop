import Foundation
// RR artefact-correction CLI for the validation scripts: one RR series per stdin line (comma-separated ms) → one JSON line per series:
// {"labels":"..E.M","nn":[...],"src":[...]}  labels: '.' normal, E ectopic, M missed, X extra, L long/short.
func code(_ a: RRArtefactCorrection.Artefact?) -> Character {
    switch a {
    case nil: return "."
    case .ectopic?: return "E"
    case .missed?: return "M"
    case .extra?: return "X"
    case .longShort?: return "L"
    }
}
while let line = readLine(strippingNewline: true) {
    let rr = line.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    let res = RRArtefactCorrection.correct(rr)
    let labels = String(res.labels.map(code))
    let nn = res.intervals.map { String(format: "%.6f", $0.rrMs) }.joined(separator: ",")
    let src = res.intervals.map { String($0.sourceIndex) }.joined(separator: ",")
    print("{\"labels\":\"\(labels)\",\"nn\":[\(nn)],\"src\":[\(src)]}")
}
