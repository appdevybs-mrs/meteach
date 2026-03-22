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

function get_bearer_token(): ?string
{
    $xAuth = $_SERVER['HTTP_X_AUTH_TOKEN'] ?? '';
    if (is_string($xAuth) && trim($xAuth) !== '') {
        return trim($xAuth);
    }

    $postToken = $_POST['auth_token'] ?? '';
    if (is_string($postToken) && trim($postToken) !== '') {
        return trim($postToken);
    }

    $getToken = $_GET['auth_token'] ?? '';
    if (is_string($getToken) && trim($getToken) !== '') {
        return trim($getToken);
    }

    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
    if (!is_string($header) || $header === '') {
        return null;
    }
    if (!preg_match('/Bearer\s+(.*)$/i', $header, $matches)) {
        return null;
    }
    $token = trim($matches[1]);
    return $token !== '' ? $token : null;
}

function firebase_factory(): Factory
{
    $credentials = getenv('GOOGLE_APPLICATION_CREDENTIALS');
    $dbUrl = getenv('FIREBASE_DB_URL');

    if (!$credentials || !$dbUrl) {
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
    $token = get_bearer_token();
    if ($token === null) {
        json_response(['success' => false, 'message' => 'Missing bearer token.'], 401);
    }

    $factory = firebase_factory();

    try {
        $verified = $factory->createAuth()->verifyIdToken($token);
    } catch (Throwable $e) {
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
