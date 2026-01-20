```
## Swift Library Package Structure

Structure for medium-sized utility packages (Networking, Analytics, etc.) with multiple related responsibilities.

MyLibrary/
├── Package.swift
├── README.md
├── Sources/
│   └── MyLibrary/
│       ├── Client/
│       ├── Caching/
│       ├── Interceptors/
│       ├── Models/
│       └── Extensions/
├── Tests/
│   └── MyLibraryTests/
│       ├── Client/
│       ├── Caching/
│       ├── Helpers/
│       │   ├── Mocks/
│       │   └── Fixtures/
│       └── Resources/
└── Documentation.docc/
    ├── Documentation.md
    └── GettingStarted.md


### Rules

- Organize by responsibility, not by type (Client/, Caching/, not Views/, ViewModels/)
- Use `public`/`internal` access control in code, not separate folders
- Tests mirror source structure
- Shared test helpers go in `Tests/*/Helpers/` with `Mocks/` and `Fixtures/` subfolders
- Test resources (JSON, etc.) go in `Tests/*/Resources/`
- Include DocC documentation with at least Documentation.md and GettingStarted.md
- Platform-specific code uses `#if os()` inline, not separate folders
- Small packages don't need subfolders - flatten if <5 files per area
```