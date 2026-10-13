// Seeded violation: a destructive action behind a native dialog.
export function DeleteClientButton({ id }: { id: string }) {
  const onClick = async () => {
    if (!window.confirm("Delete this client? This cannot be undone.")) return;
    await fetch(`/api/clients/${id}`, { method: "DELETE" });
    window.alert("Client deleted.");
  };
  return <button onClick={onClick}>Delete</button>;
}
