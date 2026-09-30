import CoreGraphics
import Foundation

guard CommandLine.arguments.contains("--send-option-command") else {
    fputs("This sends one synthetic Option+Command modifier-only event sequence.\n", stderr)
    fputs("Run with --send-option-command only while testing Kio's global shortcut.\n", stderr)
    exit(2)
}
guard CGPreflightPostEventAccess() else {
    fputs("macOS event-posting permission is unavailable.\n", stderr)
    exit(1)
}

func postModifier(_ keyCode: Int64, flags: CGEventFlags) {
    let event = CGEvent(source: nil)!
    event.type = .flagsChanged
    event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(120_000)
}

let option = CGEventFlags.maskAlternate
let command = CGEventFlags.maskCommand
postModifier(58, flags: option)
postModifier(55, flags: [option, command])
postModifier(55, flags: option)
postModifier(58, flags: [])
print("Sent one synthetic Option+Command modifier-only sequence.")
