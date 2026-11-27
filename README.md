# localSend-cli for MacOS in Swift

### localsend-cli — Send and receive files via the LocalSend v2 protocol.
### macOS 12+, Swift 5.7.

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
:white_check_mark: **Easy:** By running localsend-cli as a LaunchAgent, your Mac stays ready to receive files silently in the background. Everything automatically saves to ~/LocalSend, giving you a seamless, always-on experience without ever needing to open the GUI app.

📡 **Discovery: Why Hybrid Multicast + Subnet Fallback?**

LocalSend's native discovery relies on UDP multicast to the 224.0.0.167 group — it's fast, zero-config, and works beautifully on home networks where devices share a flat broadcast domain. However, multicast is notoriously fragile in the wild: corporate networks with AP isolation, VLAN-segmented IoT setups, strict mesh Wi-Fi systems, and guest networks all silently drop multicast packets. A CLI tool that only speaks multicast would appear broken on these networks, even though the devices are right there.

The alternative — brute-force scanning the entire /24 subnet — is equally problematic. It fires 254 HTTPS probes per interface, which is slow (1–3 seconds minimum due to connection timeouts), generates significant network noise, and can trigger intrusion detection systems on managed networks. It's also overkill on a home LAN where multicast works fine.

This CLI uses a hybrid strategy: it listens for multicast announcements first (the fast path), and only if the registry is empty after the timeout does it fall back to a targeted subnet scan. This gives you instant discovery on well-behaved networks, while still finding devices on restrictive ones — without the constant background noise of a full scan. It's a pragmatic tradeoff that prioritizes speed and quietness where possible, and resilience where necessary.

