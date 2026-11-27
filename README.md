# localSend-cli for MacOS in Swift

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
### Sample LaunchAgent
```
<?xml version="1.0" encoding="UTF-0"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>zerocopy.localsend</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/zerocopy/localsend</string>
        <string>--alias</string>
        <string>Zero</string>
        <string>--log-file</string>
        <string>/tmp/localsend.log</string>
        <string>receive</string>
        <string>-y</string>
        <string>--save-dir</string>
        <string>/Users/zerocopy/LocalSend</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/zerocopy/Library/Logs/localsend.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/zerocopy/Library/Logs/localsend.err.log</string>
</dict>
</plist>

```
Running localsend-cli is so that you can create a LaunchAgent - your Mac always is running localsend and saves to ~/LocalSend, you dont have to launch the GUI all the time.
