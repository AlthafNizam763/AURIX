import { noContent } from '@/server/http/respond';
import { withAdmin } from '@/server/middleware/auth';
import { removeFile } from '@/server/services/uploads';

/** Deletes one uploaded font file. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const DELETE = withAdmin<{ id: string }>(async (_request, { params }) => {
  await removeFile((await params).id);
  return noContent();
});
