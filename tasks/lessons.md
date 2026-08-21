# Lessons

- In zsh, `path` is a special array tied to `PATH`; never use `path` as a loop or task variable. Use a task-specific name such as `source_file` so command discovery remains intact.
- In zsh, `status` is also read-only; capture command exits in a task-specific name such as `task_exit`. Standalone simulator XCTest typechecks must add Xcode's `iPhoneSimulator.platform/Developer/Library/Frameworks` search path or `import XCTest` fails even when the SDK is correct.
- A red-first verifier must fail because of its planted violation, not because the fixture command is invalid. Validate fixture stderr and rerun with a portable producer (`awk` here) before recording non-vacuity evidence.
