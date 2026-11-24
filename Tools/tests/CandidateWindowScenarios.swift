import Cocoa
import Core
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let controller = CandidatesViewController()
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentViewController = controller
window.orderFront(nil)
controller.showCandidateIndex = true
let point = CGPoint(x: 300, y: 500)
let list = (0..<120).map { ConverterCandidatePresentation(text: "候補\($0) 排水溝", annotationText: $0 == 0 ? "ひらがな" : nil) }
var times: [Double] = []
for i in 0..<600 {
 let index = i % list.count
 let start = CFAbsoluteTimeGetCurrent()
 controller.updateCandidatePresentations(list, selectionIndex: index, cursorLocation: point)
 controller.view.layoutSubtreeIfNeeded()
 window.displayIfNeeded()
 times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
 precondition(controller.tableView.selectedRow == index)
 precondition(controller.getNumberCandidate(num: 1) <= index)
 precondition(controller.getNumberCandidate(num: 9) >= index)
}
for index in (0..<120).reversed() {
 controller.updateCandidatePresentations(list, selectionIndex: index, cursorLocation: point)
 precondition(controller.tableView.selectedRow == index)
 let first = controller.getNumberCandidate(num: 1)
 precondition(first <= index && controller.getNumberCandidate(num: 9) >= index)
 let cell = controller.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as! CandidateTableCellView
 precondition(cell.candidateTextField.stringValue.hasPrefix("\(index-first+1). "))
}
controller.updateCandidatePresentations(list, selectionIndex: nil, cursorLocation: point)
precondition(controller.tableView.selectedRow == -1)
let sorted = times.dropFirst(20).sorted()
print("navigation count=600 p50_ms=\(sorted[sorted.count/2]) p95_ms=\(sorted[sorted.count*95/100])")
// Replacement of equal-sized lists must update text and invalidate text metrics.
let originalWidth = window.frame.width
let wider = (0..<120).map { ConverterCandidatePresentation(text: "全く異なる長い候補の表示確認をしています\($0)") }
controller.updateCandidatePresentations(wider, selectionIndex: 2, cursorLocation: point)
controller.view.layoutSubtreeIfNeeded()
precondition(window.frame.width > originalWidth)
precondition(controller.tableView.numberOfRows == 120)
let cell = controller.tableView.view(atColumn: 0, row: 2, makeIfNecessary: true) as! CandidateTableCellView
precondition(cell.candidateTextField.stringValue.contains(wider[2].text))
controller.showCandidateIndex = false
controller.updateCandidatePresentations(wider, selectionIndex: 2, cursorLocation: CGPoint(x: 400,y: 600))
precondition(!cell.candidateTextField.stringValue.hasPrefix("3. "))
controller.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: point)
precondition(controller.tableView.numberOfRows == 0)
controller.hide()
controller.showCandidateIndex = true
controller.updateCandidatePresentations(list, selectionIndex: 0, cursorLocation: point)
precondition(controller.tableView.selectedRow == 0)
print("PASS list replacement, width invalidation, numbering mode, cursor relocation, empty, reopen; 600 selections")
window.orderOut(nil)
