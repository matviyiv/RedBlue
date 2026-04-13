// http.types.ts — Blue zone contract for the HTTP client layer
// Contains: generic response envelopes, pagination, error shapes
// Does NOT contain: base URLs, auth headers, axios configuration
// Implementation lives in src/utils/httpClient.ts (red zone — not visible in this workspace)

export interface ApiResponse<T> {
  data: T;
  status: number;
  message?: string;
}

export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  pageSize: number;
  hasNextPage: boolean;
}

export interface ApiErrorResponse {
  status: number;
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

// The pre-configured HTTP client instance shape.
// The real client (with baseURL from env) is in src/utils/httpClient.ts (red zone).
// Import as: import { http } from '../utils/httpClient';
// Usage:     http.get<ApiResponse<MyType>>('/path')
export interface HttpClientInstance {
  get<T>(path: string, params?: Record<string, unknown>): Promise<T>;
  post<T>(path: string, body: unknown): Promise<T>;
  put<T>(path: string, body: unknown): Promise<T>;
  patch<T>(path: string, body: unknown): Promise<T>;
  delete<T>(path: string): Promise<T>;
}
