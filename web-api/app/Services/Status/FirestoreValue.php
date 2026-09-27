<?php

namespace App\Services\Status;

/**
 * Translates between plain PHP values and the Firestore REST "Value" union.
 * Kept deliberately small: the status documents only ever hold scalars, maps
 * and lists.
 */
final class FirestoreValue
{
    /** @return array<string, mixed> */
    public static function encode(mixed $value): array
    {
        if ($value === null) {
            return ['nullValue' => null];
        }

        if (is_bool($value)) {
            return ['booleanValue' => $value];
        }

        if (is_int($value)) {
            // Firestore transports 64-bit ints as strings.
            return ['integerValue' => (string) $value];
        }

        if (is_float($value)) {
            return ['doubleValue' => $value];
        }

        if ($value instanceof \DateTimeInterface) {
            return ['timestampValue' => $value->format(\DateTimeInterface::RFC3339_EXTENDED)];
        }

        if (is_array($value)) {
            return array_is_list($value)
                ? ['arrayValue' => ['values' => array_map([self::class, 'encode'], $value)]]
                : ['mapValue' => ['fields' => self::encodeFields($value)]];
        }

        return ['stringValue' => (string) $value];
    }

    /**
     * @param  array<string, mixed>  $fields
     * @return array<string, array<string, mixed>>
     */
    public static function encodeFields(array $fields): array
    {
        $encoded = [];

        foreach ($fields as $key => $value) {
            $encoded[(string) $key] = self::encode($value);
        }

        return $encoded;
    }

    /** @param array<string, mixed> $value */
    public static function decode(array $value): mixed
    {
        return match (true) {
            array_key_exists('nullValue', $value) => null,
            array_key_exists('booleanValue', $value) => (bool) $value['booleanValue'],
            array_key_exists('integerValue', $value) => (int) $value['integerValue'],
            array_key_exists('doubleValue', $value) => (float) $value['doubleValue'],
            array_key_exists('timestampValue', $value) => (string) $value['timestampValue'],
            array_key_exists('stringValue', $value) => (string) $value['stringValue'],
            array_key_exists('arrayValue', $value) => array_map(
                [self::class, 'decode'],
                $value['arrayValue']['values'] ?? []
            ),
            array_key_exists('mapValue', $value) => self::decodeFields($value['mapValue']['fields'] ?? []),
            default => null,
        };
    }

    /**
     * @param  array<string, array<string, mixed>>  $fields
     * @return array<string, mixed>
     */
    public static function decodeFields(array $fields): array
    {
        $decoded = [];

        foreach ($fields as $key => $value) {
            $decoded[$key] = self::decode((array) $value);
        }

        return $decoded;
    }
}
