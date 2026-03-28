<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$payload = request_json();

$key = trim((string) (
    $_POST['certificateKey']
    ?? $_POST['certificate_id']
    ?? $_POST['key']
    ?? $_GET['certificateKey']
    ?? $_GET['certificate_id']
    ?? $_GET['key']
    ?? $payload['certificateKey']
    ?? $payload['certificate_id']
    ?? $payload['key']
    ?? ''
));

$cvn = trim((string) (
    $_POST['cvn']
    ?? $_GET['cvn']
    ?? $payload['cvn']
    ?? ''
));

if ($key === '') {
    json_response(['success' => false, 'message' => 'Missing certificate key.'], 400);
}

if (!preg_match('/^[A-Za-z0-9_-]{8,120}$/', $key)) {
    json_response(['success' => false, 'message' => 'Invalid certificate key.'], 400);
}

try {
    $db = firebase_factory()->createDatabase();
    $ref = $db->getReference('certificates/' . $key);
    $value = $ref->getValue();

    if (!is_array($value)) {
        json_response(['success' => false, 'message' => 'Certificate not found.'], 404);
    }

    $cert = $value;
    $certCvn = trim((string) ($cert['cvn'] ?? ''));
    if ($cvn !== '' && strcasecmp($cvn, $certCvn) !== 0) {
        json_response(['success' => false, 'message' => 'Certificate mismatch.'], 400);
    }

    $downloadsEnabled = !array_key_exists('downloadsEnabled', $cert)
        ? true
        : ($cert['downloadsEnabled'] === true);

    if (!$downloadsEnabled) {
        json_response(['success' => false, 'message' => 'Downloads are disabled.'], 403);
    }

    $current = 0;
    if (isset($cert['downloadCount']) && is_numeric($cert['downloadCount'])) {
        $current = (int) $cert['downloadCount'];
    }
    if ($current < 0) {
        $current = 0;
    }

    $next = $current + 1;
    $now = (int) round(microtime(true) * 1000);

    $ref->update([
        'downloadCount' => $next,
        'lastDownloadedAt' => $now,
        'updatedAt' => $now,
    ]);

    json_response([
        'success' => true,
        'downloadCount' => $next,
    ]);
} catch (Throwable $e) {
    json_response(['success' => false, 'message' => 'Could not update download count.'], 500);
}
