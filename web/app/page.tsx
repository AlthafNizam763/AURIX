import { redirect } from 'next/navigation';

/**
 * The root is not a landing page.
 *
 * This deployment is two things — a REST API for the mobile app and an admin
 * portal — and neither of them lives at `/`. The Express app redirected here
 * too, for the same reason.
 */
export default function Home() {
  redirect('/admin');
}
