// Driver for tests/test_installer_hides_brew_tap_warning.sh. Reads stdin lines,
// prints the ones BrewTapWarningFilter keeps ("filter") or all ("passthrough").
import Foundation
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "filter"
var f = BrewTapWarningFilter()
while let line = readLine(strippingNewline: true) {
    if mode == "passthrough" || f.keep(line) { print(line) }
}
