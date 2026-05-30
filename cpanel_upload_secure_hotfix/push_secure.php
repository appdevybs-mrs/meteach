<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

function canonical_push_type(string $raw): string
{
    $type = strtolower(trim($raw));
    if ($type === 'email') {
        return 'mail';
    }
    if ($type === 'chat') {
        return 'message';
    }
    if ($type === 'class') {
        return 'reminder';
    }
    return $type;
}

function is_allowed_push_type(string $type): bool
{
    static $allowed = [
        'message' => true,
        'reminder' => true,
        'admin_todo' => true,
        'mail' => true,
        'flash_message' => true,
        'booking' => true,
        'payment' => true,
        'recorded_comment' => true,
        'job_application' => true,
        'session' => true,
        'coach' => true,
    ];
    return isset($allowed[$type]);
}

function is_allowed_push_type_for_role(string $type, string $role): bool
{
    $safeRole = strtolower(trim($role));

    if ($safeRole === 'admin' || $safeRole === 'teacher') {
        return is_allowed_push_type($type);
    }

    if ($safeRole === 'learner') {
        return ($type === 'mail' || $type === 'booking' || $type === 'recorded_comment' || $type === 'job_application');
    }

    return false;
}

function sanitize_push_data(array $data): array
{
    $safe = [];
    foreach ($data as $k => $v) {
        $key = trim((string) $k);
        if ($key === '' || strlen($key) > 64) {
            continue;
        }
        if (!preg_match('/^[A-Za-z0-9_\-]+$/', $key)) {
            continue;
        }

        $value = trim((string) $v);
        if ($value === '') {
            continue;
        }
        if (mb_strlen($value) > 500) {
            $value = mb_substr($value, 0, 500);
        }

        $safe[$key] = $value;
        if (count($safe) >= 40) {
            break;
        }
    }
    return $safe;
}

function save_push_inbox($db, string $uid, string $eventId, string $title, string $message, string $type, array $data): void
{
    if ($uid === '') {
        return;
    }

    $db->getReference('notifications_inbox/' . $uid . '/' . $eventId)->update([
        'eventId' => $eventId,
        'type' => $type,
        'title' => $title,
        'body' => $message,
        'data' => $data,
        'status' => 'sent',
        'createdAt' => round(microtime(true) * 1000),
        'openedAt' => null,
    ]);
}

function save_push_inbox_for_admin_topic($db, string $eventId, string $title, string $message, string $type, array $data): void
{
    $adminsVal = $db->getReference('admins')->getValue();
    if (!is_array($adminsVal) || empty($adminsVal)) {
        return;
    }

    $updates = [];
    $nowMs = round(microtime(true) * 1000);

    foreach ($adminsVal as $uid => $v) {
        $safeUid = trim((string) $uid);
        if ($safeUid === '') {
            continue;
        }

        $base = 'notifications_inbox/' . $safeUid . '/' . $eventId;
        $updates[$base . '/eventId'] = $eventId;
        $updates[$base . '/type'] = $type;
        $updates[$base . '/title'] = $title;
        $updates[$base . '/body'] = $message;
        $updates[$base . '/data'] = $data;
        $updates[$base . '/status'] = 'sent';
        $updates[$base . '/createdAt'] = $nowMs;
        $updates[$base . '/openedAt'] = null;
    }

    if (!empty($updates)) {
        $db->getReference()->update($updates);
    }
}

function push_channel_for_type(string $type): string
{
    if ($type === 'message') {
        return 'ch_messages_v2';
    }

    if ($type === 'mail') {
        return 'ch_mail_v2';
    }

    if ($type === 'reminder' || $type === 'admin_todo' || $type === 'flash_message') {
        return 'ch_reminders_v2';
    }

    return 'ch_default_v2';
}

$auth = require_auth(['admin', 'teacher', 'learner']);
$payload = request_json();

$mode = strtolower(trim((string) ($payload['mode'] ?? '')));
$title = mb_substr(trim((string) ($payload['title'] ?? '')), 0, 120);
$message = mb_substr(trim((string) ($payload['message'] ?? '')), 0, 500);
$data = $payload['data'] ?? [];

if (($mode !== 'token' && $mode !== 'topic') || $title === '' || $message === '') {
    json_response(['success' => false, 'message' => 'Missing or invalid mode/title/message.'], 400);
}
if (!is_array($data)) {
    $data = [];
}

$safeData = sanitize_push_data($data);
$type = canonical_push_type((string) ($safeData['type'] ?? ''));
if ($type === '' || !is_allowed_push_type($type)) {
    json_response(['success' => false, 'message' => 'Invalid or missing data.type.'], 400);
}
$actorRole = strtolower(trim((string) ($auth['role'] ?? '')));
if (!is_allowed_push_type_for_role($type, $actorRole)) {
    json_response(['success' => false, 'message' => 'Forbidden push type for role.'], 403);
}
$safeData['type'] = $type;

$eventId = trim((string) ($safeData['eventId'] ?? ''));
if ($eventId === '' || !preg_match('/^[A-Za-z0-9_\-]{8,120}$/', $eventId)) {
    $legacySeed = implode('|', [
        $mode,
        (string) ($payload['token'] ?? $payload['topic'] ?? ''),
        $title,
        $message,
        (string) round(microtime(true) * 1000),
    ]);
    $eventId = 'legacy_' . substr(hash('sha256', $legacySeed), 0, 24);
}
$safeData['eventId'] = $eventId;

$targetValue = '';
if ($mode === 'token') {
    $targetValue = trim((string) ($payload['token'] ?? ''));
} else {
    $targetValue = trim((string) ($payload['topic'] ?? ''));
}

if ($targetValue === '') {
    json_response(['success' => false, 'message' => 'Missing notification target.'], 400);
}

if ($actorRole === 'learner' && $mode === 'topic') {
    $isUserTopic = preg_match('/^user_[A-Za-z0-9_\-]{6,128}$/', $targetValue) === 1;
    $isAdminsTopic = ($targetValue === 'admins');
    if (!$isUserTopic && !$isAdminsTopic) {
        json_response(['success' => false, 'message' => 'Learner topic not allowed.'], 403);
    }
}

$eventRef = null;

try {
    $messaging = $auth['factory']->createMessaging();
    $db = $auth['factory']->createDatabase();
    $cloudMessageClass = 'Kreait\\Firebase\\Messaging\\CloudMessage';
    $notificationClass = 'Kreait\\Firebase\\Messaging\\Notification';
    $androidConfigClass = 'Kreait\\Firebase\\Messaging\\AndroidConfig';
    $apnsConfigClass = 'Kreait\\Firebase\\Messaging\\ApnsConfig';

    $channelId = push_channel_for_type($type);
    $androidConfig = $androidConfigClass::fromArray([
        'priority' => 'high',
        'notification' => [
            'channel_id' => $channelId,
            'sound' => 'ybs_notify',
        ],
    ]);
    $apnsConfig = $apnsConfigClass::fromArray([
        'headers' => ['apns-priority' => '10'],
        'payload' => [
            'aps' => [
                'sound' => 'ybs_notify.caf',
            ],
        ],
    ]);

    $eventKey = hash('sha256', implode('|', [$eventId, $mode, $targetValue]));
    $eventRef = $db->getReference('push_events/' . $eventKey);
    $eventVal = $eventRef->getSnapshot()->getValue();
    if (is_array($eventVal) && (($eventVal['status'] ?? '') === 'sent')) {
        json_response(['success' => true, 'deduped' => true, 'eventId' => $eventId]);
    }

    $eventRef->update([
        'eventId' => $eventId,
        'status' => 'pending',
        'mode' => $mode,
        'type' => $type,
        'actorUid' => (string) ($auth['uid'] ?? ''),
        'actorRole' => (string) ($auth['role'] ?? ''),
        'title' => $title,
        'target' => $targetValue,
        'updatedAt' => round(microtime(true) * 1000),
    ]);

    if ($mode === 'token') {
        $token = trim((string) ($payload['token'] ?? ''));
        if ($token === '') {
            json_response(['success' => false, 'message' => 'Missing token.'], 400);
        }

        $msg = $cloudMessageClass::withTarget('token', $token)
            ->withNotification($notificationClass::create($title, $message))
            ->withAndroidConfig($androidConfig)
            ->withApnsConfig($apnsConfig)
            ->withData($safeData);

        $messageId = (static function() use ($messaging, $msg) {
    $r = $messaging->send($msg);
    return is_array($r) ? ($r['name'] ?? 'unknown') : $r->messageId();
})();

        $eventRef->update([
            'status' => 'sent',
            'messageId' => $messageId,
            'updatedAt' => round(microtime(true) * 1000),
        ]);

        $targetUid = trim((string) ($safeData['targetUid'] ?? ''));
        if ($targetUid !== '' && preg_match('/^[A-Za-z0-9_\-]{6,128}$/', $targetUid)) {
            save_push_inbox($db, $targetUid, $eventId, $title, $message, $type, $safeData);
        }

        json_response(['success' => true, 'eventId' => $eventId]);
    }

    if (!preg_match('/^[a-zA-Z0-9_\-\.~%]{1,120}$/', $targetValue)) {
        json_response(['success' => false, 'message' => 'Invalid topic name.'], 400);
    }

    $msg = $cloudMessageClass::withTarget('topic', $targetValue)
        ->withNotification($notificationClass::create($title, $message))
        ->withAndroidConfig($androidConfig)
        ->withApnsConfig($apnsConfig)
        ->withData($safeData);

    $messageId = (static function() use ($messaging, $msg) {
    $r = $messaging->send($msg);
    return is_array($r) ? ($r['name'] ?? 'unknown') : $r->messageId();
})();

    $eventRef->update([
        'status' => 'sent',
        'messageId' => $messageId,
        'updatedAt' => round(microtime(true) * 1000),
    ]);

    if ($targetValue === 'admins') {
        save_push_inbox_for_admin_topic($db, $eventId, $title, $message, $type, $safeData);
    }

    if (preg_match('/^user_([A-Za-z0-9_\-]{6,128})$/', $targetValue, $m) === 1) {
        $topicUid = trim((string) ($m[1] ?? ''));
        if ($topicUid !== '') {
            save_push_inbox($db, $topicUid, $eventId, $title, $message, $type, $safeData);
        }
    }

    $targetUid = trim((string) ($safeData['targetUid'] ?? ''));
    if ($targetUid !== '' && preg_match('/^[A-Za-z0-9_\-]{6,128}$/', $targetUid)) {
        save_push_inbox($db, $targetUid, $eventId, $title, $message, $type, $safeData);
    }

    json_response(['success' => true, 'eventId' => $eventId]);
} catch (Throwable $e) {
    try {
        if ($eventRef !== null) {
            $eventRef->update([
                'status' => 'failed',
                'error' => mb_substr($e->getMessage(), 0, 500),
                'updatedAt' => round(microtime(true) * 1000),
            ]);
        }
    } catch (Throwable $inner) {
    }

    json_response(['success' => false, 'message' => 'Push send failed.'], 500);
}
