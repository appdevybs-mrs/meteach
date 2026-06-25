<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

$auth = require_auth(['admin', 'teacher']);

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
const ALLOWED_EXTENSIONS = ['jpg', 'jpeg', 'png', 'webp'];

if (!isset($_FILES['file']) || !is_array($_FILES['file'])) {
    json_response(['success' => false, 'message' => 'Missing file.'], 400);
}

$tmp = (string) ($_FILES['file']['tmp_name'] ?? '');
if ($tmp === '' || !is_uploaded_file($tmp)) {
    json_response(['success' => false, 'message' => 'Invalid upload temp file.'], 400);
}

$size = (int) ($_FILES['file']['size'] ?? 0);
if ($size <= 0 || $size > MAX_UPLOAD_BYTES) {
    json_response(['success' => false, 'message' => 'File too large.'], 400);
}

$origName = (string) ($_FILES['file']['name'] ?? 'id.jpg');
$safeName = sanitize_segment(pathinfo($origName, PATHINFO_FILENAME));
$ext = strtolower((string) pathinfo($origName, PATHINFO_EXTENSION));
if ($safeName === '') {
    $safeName = 'id';
}
if ($ext === '' || !in_array($ext, ALLOWED_EXTENSIONS, true)) {
    json_response(['success' => false, 'message' => 'Only JPG, JPEG, PNG, WEBP allowed.'], 400);
}

$certName = sanitize_segment((string) ($_POST['certificate_name'] ?? 'unknown'));
if ($certName === '') {
    $certName = 'unknown';
}

$uid = (string) ($_POST['uid'] ?? $auth['uid']);

$finalName = $safeName . '_' . bin2hex(random_bytes(5)) . '.' . $ext;

$storageRoot = storage_root_dir();
$certDir = $storageRoot . '/certificates/' . $certName;
if (!is_dir($certDir) && !mkdir($certDir, 0775, true) && !is_dir($certDir)) {
    json_response(['success' => false, 'message' => 'Cannot create certificate folder.'], 500);
}

$targetPath = $certDir . '/' . $finalName;

if (!move_uploaded_file($tmp, $targetPath)) {
    json_response(['success' => false, 'message' => 'Failed to save file.'], 500);
}

$mediaBase = rtrim(getenv('YBS_PUBLIC_BASE_URL') ?: 'https://api.yourbridgeschool.com/apps/your-bridge-school/storage', '/');
$url = $mediaBase . '/certificates/' . rawurlencode($certName) . '/' . rawurlencode($finalName);

json_response([
    'success' => true,
    'url' => $url,
    'uploaderUid' => $uid,
]);
