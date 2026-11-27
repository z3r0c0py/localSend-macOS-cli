# localSend-macOS-cli

### localsend-cli — Send and receive files via the LocalSend v2 protocol.
### Swift port of the Python CLI. macOS 12+, Swift 5.7.

```
./localsend-cli --help
localsend-cli — Send and receive files via the LocalSend v2 protocol.

Usage: localsend-cli [--alias NAME] [--log-file PATH] <command>

Commands:
  send <files...> [--to NAME] [--ip IP]   Send files to a device
  receive [--save-dir DIR] [-y|--yes]     Listen for incoming transfers
  discover [-t SECONDS] [--json]          List nearby LocalSend devices
```

### Compiling
```
swiftc -O main.swift -o localsend-cli
```

### Autosave to ~/LocalSend
```
./localsend-cli receive -y --save-dir ~/LocalSend
```
