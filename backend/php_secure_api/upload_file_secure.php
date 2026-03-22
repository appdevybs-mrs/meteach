<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;
const ALLOWED_EXTENSIONS = [
    'jpg', 'jpeg', 'png', 'webp', 'gif',
    'mp4', 'm4v', 'mov', 'webm',
    'mp3', 'm4a', 'wav',
    'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'txt', 'zip',
];

if (!isset($_FILES['file']) || !is_array($_FILES['file'])) {
    json_response(['success' => false, 'message' => 'Missing file.'], 400);
}

$root = (string) ($_POST['root'] ?? '');
$path = (string) ($_POST['path'] ?? '');
$customName = sanitize_segment((string) ($_POST['custom_name'] ?? ''));

$resolved = resolve_target_path($root, $path);
ensure_parent_dir($resolved['full']);

$tmp = (string) ($_FILES['file']['tmp_name'] ?? '');
if ($tmp === '' || !is_uploaded_file($tmp)) {
    json_response(['success' => false, 'message' => 'Invalid uploaded file.'], 400);
}

$size = (int) ($_FILES['file']['size'] ?? 0);
if ($size <= 0 || $size > MAX_UPLOAD_BYTES) {
    json_response(['success' => false, 'message' => 'Invalid file size.'], 400);
}

$origName = (string) ($_FILES['file']['name'] ?? 'file.bin');
$base = $customName !== '' ? $customName : sanitize_segment(pathinfo($origName, PATHINFO_FILENAME));
if ($base === '') {
    $base = 'file';
}

$ext = strtolower((string) pathinfo($origName, PATHINFO_EXTENSION));
$safeExt = $ext === '' ? '' : sanitize_segment($ext);
if ($safeExt === '' || !in_array($safeExt, ALLOWED_EXTENSIONS, true)) {
    json_response(['success' => false, 'message' => 'File type not allowed.'], 400);
}
$finalName = $base . '_' . bin2hex(random_bytes(5)) . '.' . $safeExt;
$target = $resolved['full'] . '/' . $finalName;

if (!move_uploaded_file($tmp, $target)) {
    json_response(['success' => false, 'message' => 'Move upload failed.'], 500);
}

$rel = trim($resolved['clean'] . '/' . $finalName, '/');
$url = build_public_url($resolved['root'], $rel);

json_response(['success' => true, 'url' => $url]);
