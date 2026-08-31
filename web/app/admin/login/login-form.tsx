'use client';

import { useActionState } from 'react';
import { useFormStatus } from 'react-dom';

import { Field, Notice, buttonStyles, inputStyles } from '@components/ui';

import { signIn, type LoginState } from './actions';

/**
 * The sign-in form.
 *
 * One of only two client components in the portal, and it is one because a
 * password form that gives no feedback while it is checking a bcrypt hash —
 * which deliberately takes a moment — reads as broken. Everything else here
 * renders on the server.
 */
export function LoginForm() {
  const [state, action] = useActionState<LoginState, FormData>(signIn, {});

  return (
    <form action={action} className="space-y-4">
      {state.error ? <Notice tone="error">{state.error}</Notice> : null}

      <Field label="Email">
        <input
          className={inputStyles}
          type="email"
          name="email"
          autoComplete="username"
          required
          autoFocus
        />
      </Field>

      <Field label="Password">
        <input
          className={inputStyles}
          type="password"
          name="password"
          autoComplete="current-password"
          required
        />
      </Field>

      <Submit />
    </form>
  );
}

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button type="submit" className={`${buttonStyles.primary} w-full`} disabled={pending}>
      {pending ? 'Checking…' : 'Sign in'}
    </button>
  );
}
