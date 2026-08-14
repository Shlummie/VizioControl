const SENSITIVE_ACTION_PATTERNS = [
  /\b(buy(?: now)?|purchase|checkout|place order|confirm order|complete order|pay now|payment)\b/i,
  /\b(rent(?: now)?|rental)\b/i,
  /\b(subscribe|subscription|free trial|start (?:a )?(?:free )?trial|membership|unsubscribe|cancel (?:the )?(?:subscription|membership))\b/i,
  /\b(sign[ -]?in|log[ -]?in|login|sign[ -]?out|log[ -]?out|logout|authorize device|link account|unlink account)\b/i,
  /\b(create|add|edit|delete|remove|rename|change|manage|switch)\s+(?:a\s+|your\s+|the\s+)?(?:profiles?|accounts?)\b/i,
  /\b(?:profiles?|accounts?)\s+(?:settings|management|deactivation|deletion)\b/i,
  /\b(factory reset|reset (?:the )?(?:tv|device|app)|erase(?: all)?(?: data| settings| history| account| profile)?|delete|remove|clear(?: all)? (?:data|settings|history|watch history)|deactivate|close account|cancel account)\b/i,
] as const;

export const SENSITIVE_ACTION_CONFIRMATION_REASON = 'The TV screen appears to contain a purchase, rental, subscription, authentication, profile/account, or destructive action. Allow this action?';

const GENERIC_COMMIT_PATTERN = /\b(confirm|continue|yes|accept|agree|get started|watch now|start watching|complete|submit|next|ok|finish)\b/i;

export function containsSensitiveAction(text: string) {
  return SENSITIVE_ACTION_PATTERNS.some((pattern) => pattern.test(text));
}

export function evaluateSensitiveAction(screenText: string, focusedText: string) {
  const contextVisible = containsSensitiveAction(screenText);
  const hasReportedFocus = Boolean(focusedText) && focusedText !== 'No focused accessibility node reported.';
  const activationFocused = containsSensitiveAction(focusedText)
    || (contextVisible && GENERIC_COMMIT_PATTERN.test(focusedText))
    || (contextVisible && !hasReportedFocus);
  return { contextVisible, activationFocused };
}
