import Foundation
import SiteBlockCore

// Stub entry point: the real flag parsing, daemon runtime and watchdog are implemented separately.
FileHandle.standardError.write(Data("usage: siteblockd (--daemon | --watchdog | --version | --print-plist <daemon|watchdog|app>)\n".utf8))
exit(64)
