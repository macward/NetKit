
```swift

## Project Structure

Feature-based folder structure:

App/
├── App/
│   ├── MyAppApp.swift
│   └── Configuration/
├── Features/
│   ├── Auth/
│   │   ├── Views/
│   │   ├── ViewModels/
│   │   ├── Repositories/
│   │   └── Models/
│   ├── Home/
│   └── Settings/
├── Shared/
│   ├── Services/
│   ├── Components/
│   ├── Extensions/
│   └── Models/
├── Navigation/
└── Resources/

- Each feature contains only what it needs
- Shared/ is for code used by 2+ features
- Simple features don't need subfolders
  
  ```
