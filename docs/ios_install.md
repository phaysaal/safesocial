# Installing Spheres on iPad / iPhone

## Requirements

- **Mac** with macOS 13+ (Apple Silicon or Intel)
- **Xcode 15+** (free from App Store)
- **Flutter SDK** 3.2+
- **iPad or iPhone** running iOS 12+ (iPad 2013+ or iPhone 6s+)
- **USB cable** (Lightning or USB-C depending on your iPad model)
- **Apple ID** (free account works, or $99/year developer account)

## One-Time Setup

### 1. Install Xcode

Open the App Store on your Mac and install **Xcode**. This takes ~15GB and may take a while.

After installing, open Terminal and run:
```bash
sudo xcode-select --install
sudo xcodebuild -license accept
```

### 2. Install Flutter

```bash
brew install flutter
flutter doctor
```

Fix any issues `flutter doctor` reports (usually just Xcode command-line tools and CocoaPods).

### 3. Install CocoaPods

```bash
sudo gem install cocoapods
```

Or if using Homebrew:
```bash
brew install cocoapods
```

### 4. Clone and Set Up the Project

```bash
git clone https://github.com/phaysaal/safesocial.git
cd safesocial/safesocial_app
flutter pub get
cd ios
pod install
cd ..
```

## Build and Install on iPad

### 5. Connect Your iPad

1. Plug your iPad into the Mac via USB
2. **Trust this computer** when prompted on the iPad
3. Unlock the iPad

### 6. Open in Xcode

```bash
open ios/Runner.xcworkspace
```

> **Important:** Open `.xcworkspace`, NOT `.xcodeproj`

### 7. Configure Signing

In Xcode:

1. Click on **Runner** in the left sidebar (the blue project icon at the top)
2. Select the **Runner** target
3. Go to **Signing & Capabilities** tab
4. Check **Automatically manage signing**
5. Set **Team** to your Apple ID
   - If you don't see your Apple ID, go to Xcode → Settings → Accounts → Add your Apple ID
6. Change **Bundle Identifier** to something unique:
   ```
   com.yourname.spheres
   ```
   (Apple requires unique bundle IDs — use your name or domain)

### 8. Select Your iPad

In the top toolbar of Xcode, click the device dropdown and select your iPad.

If your iPad doesn't appear:
- Make sure it's unlocked and connected
- Try unplugging and reconnecting
- Go to Window → Devices and Simulators to check

### 9. Build and Run

Click the **Play button** (▶) or press **Cmd + R**.

The first build takes 5-10 minutes (compiling Veilid from Rust source). Subsequent builds are faster.

### 10. Trust the Developer Profile on iPad

The first time you install, the iPad will refuse to open the app. To fix:

1. On iPad, go to **Settings → General → VPN & Device Management**
2. Find your Apple ID under "Developer App"
3. Tap **Trust "your@email.com"**
4. Tap **Trust** again to confirm
5. Now open the Spheres app — it will work

## Re-signing (Free Apple ID)

With a **free Apple ID**, the app expires after **7 days**. To reinstall:

1. Connect iPad to Mac
2. Open Xcode
3. Click Play (▶) again

With a **paid developer account** ($99/year), you can:
- Build once and it lasts **1 year**
- Distribute via **TestFlight** (no USB needed, up to 10,000 testers)
- Publish to the **App Store**

## TestFlight Distribution (Paid Account Only)

If you have a $99/year Apple Developer account:

```bash
# Build the IPA
flutter build ipa

# The IPA will be at:
# build/ios/ipa/sphere_app.ipa
```

Then:
1. Open **Transporter** app on Mac (free from App Store)
2. Drag the `.ipa` file into Transporter
3. Click **Deliver**
4. Go to [App Store Connect](https://appstoreconnect.apple.com)
5. Create a new app → Add the build → Enable TestFlight
6. Share the TestFlight link with testers

## Troubleshooting

### "Untrusted Developer" error on iPad
→ Settings → General → VPN & Device Management → Trust your profile

### "Unable to install" or provisioning error
→ In Xcode, change the Bundle Identifier to something unique

### CocoaPods errors
```bash
cd ios
pod deintegrate
pod install
cd ..
flutter clean
flutter pub get
```

### Xcode build fails with "No signing certificate"
→ Xcode → Settings → Accounts → Download Manual Profiles

### Build takes too long
The first build compiles Veilid (Rust) for iOS — this takes ~10 minutes.
Subsequent builds are much faster (~1-2 minutes).

### App crashes on old iPad
Spheres requires iOS 12+. Check Settings → General → About → Software Version.
