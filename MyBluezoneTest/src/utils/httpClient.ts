// RED ZONE — base client
import axios from 'axios';
export const http = axios.create({ baseURL: process.env.API_BASE_URL });
