#!/usr/bin/env bash
# generate-test-project.sh

# 1. Scaffold real RN project
npx @react-native-community/cli@latest init MyBluezoneTest --template react-native-template-typescript
cd MyBluezoneTest

# 2. Create realistic RED zone files in src/
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
echo "API_BASE_URL=https://api.internal.myapp.com" > .env.local
echo "JITSI_SERVER=https://jitsi.internal.myapp.com" >> .env.local
echo "AUTH_TOKEN_SECRET=super-secret-key" >> .env.local
cp .env.local .env.production

# 4. Create RED zone signing placeholders
echo "FAKE_CERT" > ios/MyBluezoneTest/MyApp.p12
echo "FAKE_PROVISION" > ios/MyBluezoneTest/MyApp.mobileprovision
echo "{ \"api_key\": \"AIza_fake_firebase_key\" }" > ios/MyBluezoneTest/GoogleService-Info.plist
echo "storePassword=my-secret-store-pw" > android/keystore.properties
echo "{ \"project_id\": \"myapp\", \"api_key\": \"fake\" }" > android/app/google-services.json
echo "FAKEKEYSTORE" > android/app/release.jks

# 5. Copy blue zone docker setup into project
cp -r /path/to/claude-docker-setup/* .
