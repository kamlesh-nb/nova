// C# peer: ASP.NET Core minimal API on Kestrel. GET / returns a constant JSON body.
var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
var app = builder.Build();
app.MapGet("/", () => Results.Content("{\"message\":\"Hello, World!\"}", "application/json"));
var port = Environment.GetEnvironmentVariable("PORT") ?? "8083";
app.Run($"http://0.0.0.0:{port}");
