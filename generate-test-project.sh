#!/usr/bin/env bash
set -e
# generate-test-project.sh
# Manually scaffolds a realistic RN project structure (no network required)

PROJECT=MyBluezoneTest

# 1. Scaffold RN project structure
mkdir -p "$PROJECT"/{src/{api,services,utils,components,screens},ios/{"$PROJECT","$PROJECT".xcodeproj},android/{app/src/main,gradle/wrapper}}

cd "$PROJECT"

# package.json
cat > package.json << 'EOF'
{
  "name": "MyBluezoneTest",
  "version": "0.0.1",
  "private": true,
  "scripts": {
    "android": "react-native run-android",
    "ios": "react-native run-ios",
    "start": "react-native start",
    "test": "jest",
    "lint": "eslint ."
  },
  "dependencies": {
    "axios": "^1.6.0",
    "react": "18.3.1",
    "react-native": "0.76.5"
  },
  "devDependencies": {
    "@babel/core": "^7.20.0",
    "@babel/preset-env": "^7.20.0",
    "@babel/runtime": "^7.20.0",
    "@react-native/babel-preset": "0.76.5",
    "@react-native/eslint-config": "0.76.5",
    "@react-native/metro-config": "0.76.5",
    "@react-native/typescript-config": "0.76.5",
    "@types/react": "^18.2.6",
    "@types/react-test-renderer": "^18.0.0",
    "eslint": "^8.19.0",
    "jest": "^29.6.3",
    "prettier": "2.8.8",
    "react-test-renderer": "18.3.1",
    "typescript": "5.0.4"
  },
  "engines": {
    "node": ">=18"
  }
}
EOF

# tsconfig.json
cat > tsconfig.json << 'EOF'
{
  "extends": "@react-native/typescript-config/tsconfig.json"
}
EOF

# index.js
cat > index.js << 'EOF'
import {AppRegistry} from 'react-native';
import App from './App';
import {name as appName} from './app.json';

AppRegistry.registerComponent(appName, () => App);
EOF

# app.json
cat > app.json << 'EOF'
{
  "name": "MyBluezoneTest",
  "displayName": "MyBluezoneTest"
}
EOF

# App.tsx
cat > App.tsx << 'EOF'
import React from 'react';
import {SafeAreaView, Text, StyleSheet} from 'react-native';

function App(): React.JSX.Element {
  return (
    <SafeAreaView style={styles.container}>
      <Text style={styles.title}>MyBluezoneTest</Text>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, justifyContent: 'center', alignItems: 'center'},
  title: {fontSize: 24, fontWeight: 'bold'},
});

export default App;
EOF

# babel.config.js
cat > babel.config.js << 'EOF'
module.exports = {
  presets: ['module:@react-native/babel-preset'],
};
EOF

# metro.config.js
cat > metro.config.js << 'EOF'
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');
const config = {};
module.exports = mergeConfig(getDefaultConfig(__dirname), config);
EOF

# .gitignore
cat > .gitignore << 'EOF'
node_modules/
.env
.env.local
.env.production
*.p12
*.mobileprovision
GoogleService-Info.plist
google-services.json
keystore.properties
*.jks
/android/app/debug.keystore
/ios/build
/android/build
/android/app/build
EOF

# Android files
cat > android/build.gradle << 'EOF'
buildscript {
    ext {
        buildToolsVersion = "34.0.0"
        minSdkVersion = 24
        compileSdkVersion = 34
        targetSdkVersion = 34
    }
    repositories { google(); mavenCentral() }
    dependencies {
        classpath("com.android.tools.build:gradle:8.1.4")
        classpath("com.google.gms:google-services:4.4.0")
    }
}
EOF

cat > android/app/build.gradle << 'EOF'
apply plugin: "com.android.application"
apply plugin: "com.google.gms.google-services"

android {
    namespace "com.mybluezonetest"
    compileSdkVersion rootProject.ext.compileSdkVersion
    defaultConfig {
        applicationId "com.mybluezonetest"
        minSdkVersion rootProject.ext.minSdkVersion
        targetSdkVersion rootProject.ext.targetSdkVersion
        versionCode 1
        versionName "1.0"
    }
    signingConfigs {
        release {
            storeFile file(KEYSTORE_FILE)
            storePassword KEYSTORE_PASSWORD
            keyAlias KEY_ALIAS
            keyPassword KEY_PASSWORD
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.release
            minifyEnabled true
        }
    }
}
EOF

cat > android/app/src/main/AndroidManifest.xml << 'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application android:name=".MainApplication" android:label="@string/app_name">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

# iOS files
cat > ios/"$PROJECT".xcodeproj/project.pbxproj << 'EOF'
// Stub Xcode project — replace with real generated project
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {}; }
EOF

cat > ios/Podfile << 'EOF'
platform :ios, '15.1'
require_relative '../node_modules/react-native/scripts/react_native_pods'
target 'MyBluezoneTest' do
  config = use_native_modules!
  use_react_native!(:path => config[:reactNativePath])
end
EOF

# Shared blue-zone component (not RED)
cat > src/components/Button.tsx << 'EOF'
import React from 'react';
import {TouchableOpacity, Text, StyleSheet} from 'react-native';

interface Props { title: string; onPress: () => void; }

export const Button: React.FC<Props> = ({title, onPress}) => (
  <TouchableOpacity style={styles.btn} onPress={onPress}>
    <Text style={styles.text}>{title}</Text>
  </TouchableOpacity>
);

const styles = StyleSheet.create({
  btn: {backgroundColor: '#007AFF', padding: 12, borderRadius: 8},
  text: {color: '#fff', fontWeight: '600'},
});
EOF

cat > src/screens/HomeScreen.tsx << 'EOF'
import React from 'react';
import {View, Text} from 'react-native';
import {Button} from '../components/Button';

export const HomeScreen: React.FC = () => (
  <View>
    <Text>Home</Text>
    <Button title="Go" onPress={() => {}} />
  </View>
);
EOF

# 2. Create realistic RED zone source files
cat > src/api/auth-api.ts << 'EOF'
// RED ZONE — endpoint file, should be filtered by prepare-blue-zone.sh
import axios from 'axios';
const BASE = process.env.API_BASE_URL;
export const authApi = {
  login: (email: string, pw: string) =>
    axios.post(`${BASE}/auth/login`, { email, pw }),
};
EOF

cat > src/services/jitsiService.ts << 'EOF'
// RED ZONE — internal server reference
const JITSI = process.env.JITSI_SERVER;
export const joinRoom = (room: string) => `${JITSI}/${room}`;
EOF

cat > src/utils/httpClient.ts << 'EOF'
// RED ZONE — base client
import axios from 'axios';
export const http = axios.create({ baseURL: process.env.API_BASE_URL });
EOF

# 3. Create RED zone env files
printf "API_BASE_URL=https://api.internal.myapp.com\nJITSI_SERVER=https://jitsi.internal.myapp.com\nAUTH_TOKEN_SECRET=super-secret-key\n" > .env.local
cp .env.local .env.production

# 4. Create RED zone signing placeholders
echo "FAKE_CERT" > ios/"$PROJECT"/MyApp.p12
echo "FAKE_PROVISION" > ios/"$PROJECT"/MyApp.mobileprovision
echo '{ "api_key": "AIza_fake_firebase_key" }' > ios/"$PROJECT"/GoogleService-Info.plist
echo "storePassword=my-secret-store-pw" > android/keystore.properties
echo '{ "project_id": "myapp", "api_key": "fake" }' > android/app/google-services.json
echo "FAKEKEYSTORE" > android/app/release.jks

# 5. Copy blue zone docker setup into project
# TODO: replace placeholder path once claude-docker-setup is provided
# cp -r /path/to/claude-docker-setup/* .

echo ""
echo "✓ $PROJECT scaffolded successfully"
echo ""
echo "  BLUE zone files:"
echo "    App.tsx, index.js, package.json, tsconfig.json"
echo "    src/components/Button.tsx"
echo "    src/screens/HomeScreen.tsx"
echo ""
echo "  RED zone source files:"
echo "    src/api/auth-api.ts"
echo "    src/services/jitsiService.ts"
echo "    src/utils/httpClient.ts"
echo ""
echo "  RED zone env files:"
echo "    .env.local, .env.production"
echo ""
echo "  RED zone signing files:"
echo "    ios/$PROJECT/MyApp.p12"
echo "    ios/$PROJECT/MyApp.mobileprovision"
echo "    ios/$PROJECT/GoogleService-Info.plist"
echo "    android/keystore.properties"
echo "    android/app/google-services.json"
echo "    android/app/release.jks"
