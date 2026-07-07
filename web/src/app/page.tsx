import LeadForm from "@/components/LeadForm";

export default function Home() {
  return (
    <main
      style={{
        display: "flex",
        minHeight: "100vh",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: "1.5rem",
        fontFamily: "system-ui, sans-serif",
        textAlign: "center",
        padding: "2rem",
      }}
    >
      <div>
        <h1>Lead Intelligence Pipeline</h1>
        <p>Tell us about your business and we&apos;ll be in touch.</p>
      </div>
      <LeadForm />
    </main>
  );
}
