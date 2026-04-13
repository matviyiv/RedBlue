// auth.types.ts — Blue zone contract for the authentication API layer
// Contains: request/response shapes, session state, error types
// Does NOT contain: URLs, tokens, implementation details
// Implementation lives in src/api/auth-api.ts (red zone — not visible in this workspace)

export interface LoginRequest {
  email: string;
  password: string;
}

export interface LoginResponse {
  userId: string;
  accessToken: string;
  refreshToken: string;
  expiresAt: number; // Unix timestamp (ms)
}

export type AuthErrorCode =
  | 'INVALID_CREDENTIALS'
  | 'ACCOUNT_LOCKED'
  | 'TOKEN_EXPIRED'
  | 'NETWORK_ERROR'
  | 'UNKNOWN';

export interface AuthError {
  code: AuthErrorCode;
  message: string;
}

export interface AuthSession {
  userId: string;
  email: string;
  isAuthenticated: boolean;
  expiresAt: number;
}

// Function signature contract — the concrete implementation lives in the red zone.
// Accept this interface as a prop or via context; do not import the implementation directly.
export interface IAuthApi {
  login(request: LoginRequest): Promise<LoginResponse>;
  logout(): Promise<void>;
  refreshSession(): Promise<LoginResponse>;
}
