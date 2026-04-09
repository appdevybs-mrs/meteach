<?php
declare(strict_types=1);

use Kreait\Firebase\Factory;

require_once __DIR__ . '/vendor/autoload.php';

function json_response(array $data, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE);
    exit;
}

function request_json(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || trim($raw) === '') {
        return [];
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

function secure_log(string $message, array $context = []): void
{
    $endpoint = basename((string) ($_SERVER['SCRIPT_NAME'] ?? 'unknown'));
    if (!empty($context)) {
        error_log('[secure/bootstrap] ' . $message . ' endpoint=' . $endpoint . ' ' . json_encode($context));
        return;
    }
    error_log('[secure/bootstrap] ' . $message . ' endpoint=' . $endpoint);
}

function get_bearer_token_details(): array
{
    if (function_exists('getallheaders')) {
        $headers = getallheaders();
        if (is_array($headers)) {
            foreach ($headers as $k => $v) {
                $key = strtolower((string) $k);
                $val = is_string($v) ? trim($v) : '';
                if ($val === '') {
                    continue;
                }

                if ($key === 'x-auth-token') {
                    return ['token' => $val, 'source' => 'x_auth_header'];
                }

                if ($key === 'authorization' && preg_match('/Bearer\s+(.*)$/i', $val, $m)) {
                    $token = trim((string) ($m[1] ?? ''));
                    if ($token !== '') {
                        return ['token' => $token, 'source' => 'authorization_header'];
                    }
                }
            }
        }
    }

    if (isset($_SERVER['HTTP_X_AUTH_TOKEN']) && is_string($_SERVER['HTTP_X_AUTH_TOKEN'])) {
        $xAuth = trim((string) $_SERVER['HTTP_X_AUTH_TOKEN']);
        if ($xAuth !== '') {
            return ['token' => $xAuth, 'source' => 'x_auth_header'];
        }
    }

    $authHeader = (string) ($_SERVER['HTTP_AUTHORIZATION'] ?? '');
    if ($authHeader === '') {
        $authHeader = (string) ($_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
    }
    if ($authHeader !== '' && preg_match('/Bearer\s+(.*)$/i', $authHeader, $m)) {
        $token = trim((string) ($m[1] ?? ''));
        if ($token !== '') {
            return ['token' => $token, 'source' => 'authorization_header'];
        }
    }

    $candidates = [
        $_POST['auth_token'] ?? null,
        $_POST['token'] ?? null,
        $_POST['at'] ?? null,
        $_POST['t'] ?? null,
        $_GET['auth_token'] ?? null,
        $_GET['token'] ?? null,
        $_GET['at'] ?? null,
        $_GET['t'] ?? null,
    ];

    foreach ($candidates as $candidate) {
        if (is_string($candidate) && trim($candidate) !== '') {
            return ['token' => trim($candidate), 'source' => 'request_fallback'];
        }
    }

    $qs = (string) ($_SERVER['QUERY_STRING'] ?? '');
    if ($qs !== '') {
        $parsed = [];
        parse_str($qs, $parsed);
        if (is_array($parsed)) {
            foreach (['auth_token', 'token', 'at', 't'] as $k) {
                $v = $parsed[$k] ?? null;
                if (is_string($v) && trim($v) !== '') {
                    return ['token' => trim($v), 'source' => 'request_fallback'];
                }
            }
        }
    }

    return ['token' => null, 'source' => 'none'];
}

function get_bearer_token(): ?string
{
    $details = get_bearer_token_details();
    return isset($details['token']) && is_string($details['token']) ? $details['token'] : null;
}

function auth_token_is_placeholder(string $token): bool
{
    $v = strtolower(trim($token));
    return in_array($v, ['null', 'none', 'undefined', 'false', 'true', 'nan'], true);
}

function auth_token_looks_like_jwt(string $token): bool
{
    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        return false;
    }

    foreach ($parts as $part) {
        if ($part === '' || !preg_match('/^[A-Za-z0-9\-_]+$/', $part)) {
            return false;
        }
    }

    return true;
}

function firebase_factory(): Factory
{
    $credentials = getenv('GOOGLE_APPLICATION_CREDENTIALS');
    $dbUrl = getenv('FIREBASE_DB_URL');

    $credentials = is_string($credentials) ? trim($credentials) : '';
    $dbUrl = is_string($dbUrl) ? trim($dbUrl) : '';

    if ($credentials === '' || $dbUrl === '') {
        $cfgPath = __DIR__ . '/secure_config.php';
        if (is_file($cfgPath) && is_readable($cfgPath)) {
            try {
                $cfg = include $cfgPath;
                if (is_array($cfg)) {
                    if ($credentials === '') {
                        $v = $cfg['GOOGLE_APPLICATION_CREDENTIALS'] ?? '';
                        if (is_string($v) && trim($v) !== '') {
                            $credentials = trim($v);
                        }
                    }
                    if ($dbUrl === '') {
                        $v = $cfg['FIREBASE_DB_URL'] ?? '';
                        if (is_string($v) && trim($v) !== '') {
                            $dbUrl = trim($v);
                        }
                    }
                }
            } catch (Throwable $e) {
                secure_log('secure_config load failed', ['error' => $e->getMessage()]);
            }
        }
    }

    if ($credentials === '' || $dbUrl === '') {
        json_response([
            'success' => false,
            'message' => 'Server misconfiguration: missing Firebase env vars.',
        ], 500);
    }

    return (new Factory())
        ->withServiceAccount($credentials)
        ->withDatabaseUri($dbUrl);
}

function require_auth(array $allowedRoles = []): array
{
    $tokenDetails = get_bearer_token_details();
    $source = (string) ($tokenDetails['source'] ?? 'none');
    $token = isset($tokenDetails['token']) && is_string($tokenDetails['token']) ? $tokenDetails['token'] : null;

    if ($token === null) {
        secure_log('token missing', ['source' => $source]);
        json_response(['success' => false, 'message' => 'Missing bearer token.'], 401);
    }

    if (auth_token_is_placeholder($token)) {
        secure_log('token rejected', ['source' => $source, 'reason' => 'placeholder', 'len' => strlen($token)]);
        json_response(['success' => false, 'message' => 'Invalid bearer token.'], 401);
    }

    if (!auth_token_looks_like_jwt($token)) {
        secure_log('token rejected', ['source' => $source, 'reason' => 'not_jwt_shape', 'len' => strlen($token)]);
        json_response(['success' => false, 'message' => 'Invalid bearer token.'], 401);
    }

    $factory = firebase_factory();

    try {
        $verified = $factory->createAuth()->verifyIdToken($token);
    } catch (Throwable $e) {
        secure_log('verifyIdToken failed', ['source' => $source, 'len' => strlen($token), 'error' => $e->getMessage()]);
        json_response(['success' => false, 'message' => 'Invalid auth token.'], 401);
    }

    $uid = (string) ($verified->claims()->get('sub') ?? '');
    if ($uid === '') {
        json_response(['success' => false, 'message' => 'Invalid auth uid.'], 401);
    }

    $role = '';
    $claimRole = $verified->claims()->get('role');
    if (is_string($claimRole) && trim($claimRole) !== '') {
      $role = strtolower(trim($claimRole));
    }

    if ($role !== '' && !empty($allowedRoles) && in_array($role, $allowedRoles, true)) {
      return ['uid' => $uid, 'role' => $role, 'factory' => $factory];
    }

    try {
        $roleVal = $factory->createDatabase()->getReference('users/' . $uid . '/role')->getValue();
        $role = is_string($roleVal) ? strtolower(trim($roleVal)) : '';
    } catch (Throwable $e) {
        json_response(['success' => false, 'message' => 'Unable to read user role.'], 500);
    }

    if (!empty($allowedRoles) && !in_array($role, $allowedRoles, true)) {
        json_response(['success' => false, 'message' => 'Forbidden.'], 403);
    }

    return ['uid' => $uid, 'role' => $role, 'factory' => $factory];
}

function sanitize_segment(string $segment): string
{
    $segment = trim($segment);
    $segment = preg_replace('/[^a-zA-Z0-9_\-\.]/', '_', $segment) ?? '';
    $segment = preg_replace('/_+/', '_', $segment) ?? '';
    return trim($segment, '._');
}

function sanitize_rel_path(string $path): string
{
    $parts = array_filter(explode('/', str_replace('\\', '/', $path)), static fn ($p) => trim($p) !== '');
    $safeParts = [];
    foreach ($parts as $part) {
        if ($part === '.' || $part === '..') {
            continue;
        }
        $safe = sanitize_segment((string) $part);
        if ($safe !== '') {
            $safeParts[] = $safe;
        }
    }
    return implode('/', $safeParts);
}
