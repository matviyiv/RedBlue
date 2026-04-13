// RED ZONE — endpoint file, should be filtered by prepare-blue-zone.sh
import axios from 'axios';
const BASE = process.env.API_BASE_URL;
export const authApi = {
  login: (email: string, pw: string) =>
    axios.post(`${BASE}/auth/login`, { email, pw }),
};
