<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$authCtx = require_auth();
$factory = $authCtx['factory'];
$adminUid = (string) $authCtx['uid'];

$payload = request_json();
$targetUid = trim((string) ($payload['targetUid'] ?? $_POST['targetUid'] ?? $_GET['targetUid'] ?? ''));
$newEmail = trim((string) ($payload['newEmail'] ?? $_POST['newEmail'] ?? $_GET['newEmail'] ?? ''));

if ($targetUid === '') {
    json_response(['success' => false, 'message' => 'Missing targetUid.'], 400);
}

if ($newEmail === '') {
    json_response(['success' => false, 'message' => 'Missing newEmail.'], 400);
}

if (!preg_match('/^[A-Za-z0-9:_-]{6,128}$/', $targetUid)) {
    json_response(['success' => false, 'message' => 'Invalid targetUid.'], 400);
}

if (!filter_var($newEmail, FILTER_VALIDATE_EMAIL)) {
    json_response(['success' => false, 'message' => 'Invalid email format.'], 400);
}

try {
    $db = $factory->createDatabase();
    $adminNode = $db->getReference('admins/' . $adminUid)->getValue();

    $isAdmin = false;
    if ($adminNode === true) {
        $isAdmin = true;
    } elseif (is_array($adminNode) && !empty($adminNode)) {
        $isAdmin = true;
    }

    if (!$isAdmin) {
        json_response(['success' => false, 'message' => 'Forbidden. Admin only.'], 403);
    }
} catch (Throwable $e) {
    json_response(['success' => false, 'message' => 'Unable to verify admin access.'], 500);
}

try {
    $firebaseAuth = $factory->createAuth();
    $firebaseAuth->updateUser($targetUid, ['email' => $newEmail]);

    json_response([
        'success' => true,
        'updatedUid' => $targetUid,
        'updatedEmail' => $newEmail,
        'updatedBy' => $adminUid,
    ]);
} catch (Throwable $e) {
    $msg = strtolower(trim($e->getMessage()));

    if (str_contains($msg, 'email already in use')) {
        json_response([
            'success' => false,
            'message' => 'Email is already in use by another account.',
        ], 409);
    }

    if (str_contains($msg, 'not found') || str_contains($msg, 'no user')) {
        json_response([
            'success' => false,
            'message' => 'User not found.',
        ], 404);
    }

    if (str_contains($msg, 'invalid email')) {
        json_response([
            'success' => false,
            'message' => 'Invalid email format.',
        ], 400);
    }

    json_response([
        'success' => false,
        'message' => 'Email update failed.',
        'error' => $e->getMessage(),
    ], 500);
}
