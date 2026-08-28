# Video 19: Package management

- Chapter: [19-package-management.md](../19-package-management.md)
- Estimated length: ~11 minutes
- You will need: Nova installed, `git` on your PATH, and a terminal. Watching Video 14 on modules first helps, since imports build on it.

## Hook (0:00)

**Say:** Every real project pulls in code someone else wrote. In this video you will see how Nova does dependencies, and the short version is: there is no registry, no account, and no separate package tool. A dependency is a git repository named by its URL, and the same `nova` compiler that builds your code fetches and pins it. If you know Go modules, you already know the shape.

## What we will cover (0:30)

**On screen:**
```
- project.json: the manifest the build reads
- nova get: add a dependency (git URL, like go get)
- project.lock.json: reproducible, offline builds
- nova init: console / web / desktop
- How an import finds a module
- nova build / test / fmt (there is no nova run)
- nova publish: a git tag, nothing more
```

## Segment: The project.json manifest (1:00)

**Say:** Every project has a project.json at its root. It names the project and lists dependencies, and each dependency is a git URL.

**On screen:**
```json
{
  "name": "nova-pg-web",
  "version": "0.1.0",
  "type": "web",
  "dependencies": [
    "https://github.com/kamlesh-nb/nova-postgres"
  ]
}
```

**Say:** name drives the output binary name and the cache directory. version is only read by publish, where it becomes a git tag. type is a free-form label; the build does not branch on it. dependencies is an array of git URLs, and you can pin one with a hash-ref suffix: hash v1.2.0, a branch, or a full commit SHA. An empty dependencies array is completely normal.

## Segment: nova get (2:30)

**Say:** You add a dependency with nova get. Note the name, following Go's go get. There is no nova add package and no nova install.

**On screen:**
```bash
nova get https://github.com/kamlesh-nb/nova-postgres
```

**Say:** That appends the URL to project.json, then resolves the whole tree and writes the lockfile. Resolution clones each repo into a shared cache, checks out the requested ref, reads that dependency's own project.json, and pulls in its dependencies too, breadth-first, de-duplicating diamonds. The cache is content-addressed: cache slash name-dash-first-eight-of-the-commit-SHA, so two projects on the same commit share one checkout. Git runs as ordinary subprocesses, so private repos work exactly as your git credentials allow.

**On screen:**
```nova
import postgres;
import db;
let conn = await postgres.PgDriver().connect("postgresql://user:pass@127.0.0.1:5432/mydb");
```

## Segment: The lockfile and reproducible builds (4:30)

**Say:** project.lock.json records the exact commit each dependency resolved to. Generate it, commit it to version control, and here is the important property: once the lock exists, nova build reuses the locked commit and the existing cache and does no network access at all. A plain build is offline and reproducible. Only nova update re-fetches a moving ref.

**On screen:**
```
nova restore        # resolve from project.json, write the lock (after a fresh clone)
nova update [url]   # advance floating deps to the tip, rewrite the lock
```

**Say:** You rarely run restore by hand, because every project build resolves first anyway, and only rewrites the lock when resolution actually changed.

## Segment: nova init (6:00)

**Say:** You scaffold a project with nova init, in one of three kinds.

**On screen:**
```bash
nova init web     --name myapp
nova init console --name mytool
nova init desktop --name mywidget
```

**Say:** All three write project.json, a gitignore, and VS Code files. console gives you a main and a test. web gives you the full vertical-slice tree from Video 17, plus the Tailwind files. desktop gives you a main. nova init app is a deprecated alias for web. There is also nova add feature name, which scaffolds a new slice inside a project; that is the only thing nova add does, and it is not how you add a dependency.

## Segment: How an import finds a module (7:30)

**Say:** An import names a module, and the compiler maps it to a dot-nova file by trying a sequence of locations and taking the first hit: the standard library and built-ins first, then sibling and ancestor files in your own project, then locked dependency packages in the cache, then a local packages folder, then a filename scan of the cache.

**On screen:**
```
import db;          -> standard library (the database seam)
import postgres;    -> a dependency (the driver)
```

**Say:** The practical rule: a package's importable name is the name of the dot-nova file under its src directory, not the repository name. The PostgreSQL driver lives in a repo called nova-postgres, but its module file is src slash postgres dot nova, so you write import postgres. The convention is a repo named nova-something whose module is that something.

## Segment: build, test, and there is no run (9:00)

**Say:** The compiler's subcommands are the whole interface.

**On screen:**
```
nova build                 # reads project.json, writes build/<profile>/bin
nova <file>.nova -o out    # compile one file, no project needed
nova test [<file>]         # run @test functions
nova fmt [<file>]          # format
nova version               # compiler + ABI version
```

**Say:** One thing to state plainly: there is no nova run. To run a project you build it and execute the binary under build slash profile slash bin, or for a one-off you compile a single file and run it.

## Segment: Publishing (10:00)

**Say:** Publishing a Nova package means creating a git tag. There is no server to upload to. nova publish requires type library and a repository URL, turns your version into the tag v-version, and pushes it. Then a consumer pins that release with the hash-ref suffix on the URL.

**On screen:**
```bash
nova publish
# consumers then:
nova get https://github.com/you/nova-widget#v0.1.0
```

## Recap (10:45)

**Say:** That is Nova's package management. Dependencies are git URLs in project.json, nova get fetches and pins them, the lockfile makes builds offline and reproducible, imports resolve by module filename, and publishing is just a tag. In the next video we put this to work: adding the database drivers, each with its git URL, its import, and its connection string.

**On screen:**
```
Next: Video 20, Database drivers
```
