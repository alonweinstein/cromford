// Clean: the same destructive action behind the project's in-app modal.
import { useState } from "react";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { useToast } from "@/components/toast";

export function DeleteClientButton({ id }: { id: string }) {
  const [asking, setAsking] = useState(false);
  const toast = useToast();
  const confirmDelete = async () => {
    setAsking(false);
    await fetch(`/api/clients/${id}`, { method: "DELETE" });
    toast("Client deleted.");
  };
  return (
    <>
      <button onClick={() => setAsking(true)}>Delete</button>
      <ConfirmDialog
        open={asking}
        title="Delete this client?"
        body="This cannot be undone."
        onCancel={() => setAsking(false)}
        onConfirm={confirmDelete}
      />
    </>
  );
}
