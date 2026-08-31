'use client';

import { useActionState } from 'react';

import { Notice, buttonStyles } from '@components/ui';

import { setAdmin, type RoleState } from './actions';

/**
 * Promote or demote one account.
 *
 * A client component only so the result of the action — "that is the only
 * administrator" in particular — can be shown next to the button that caused it
 * rather than at the top of a re-rendered page.
 */
export function RoleToggle({
  uid,
  isAdmin,
  isSelf,
}: {
  uid: string;
  isAdmin: boolean;
  isSelf: boolean;
}) {
  const [state, action, pending] = useActionState<RoleState, FormData>(setAdmin, {});

  if (isSelf) {
    return (
      <span className="text-xs text-ink-tertiary" title="Ask another administrator.">
        You
      </span>
    );
  }

  return (
    <div className="flex flex-col items-end gap-2">
      <form action={action}>
        <input type="hidden" name="uid" value={uid} />
        <input type="hidden" name="isAdmin" value={String(!isAdmin)} />
        <button
          type="submit"
          className={isAdmin ? buttonStyles.ghost : buttonStyles.secondary}
          disabled={pending}
        >
          {pending ? '…' : isAdmin ? 'Revoke admin' : 'Make admin'}
        </button>
      </form>

      {state.error ? (
        <div className="max-w-xs text-left">
          <Notice tone="error">{state.error}</Notice>
        </div>
      ) : null}
    </div>
  );
}
