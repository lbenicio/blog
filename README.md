# Blog - Personal blog

![GitHub License](https://img.shields.io/github/license/lbenicio/lbenicio.github.io?style=flat&color=blue)
![GitHub Release](https://img.shields.io/github/v/release/lbenicio/lbenicio.github.io?color=blue)
[![CodeQL](https://github.com/lbenicio/lbenicio.github.io/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/lbenicio/lbenicio.github.io/actions/workflows/github-code-scanning/codeql)
[![Build and Publish Docker Image](https://github.com/lbenicio/lbenicio.github.io/actions/workflows/release.yml/badge.svg)](https://github.com/lbenicio/lbenicio.github.io/actions/workflows/release.yml)
[![Build and Deploy to GitHub Pages](https://github.com/lbenicio/lbenicio.github.io/actions/workflows/deploy.yml/badge.svg)](https://github.com/lbenicio/lbenicio.github.io/actions/workflows/deploy.yml)

A modern, fast, and accessible personal website built with Hugo and the aboutme-v2-theme. This site showcases professional background, research publications, reading list, timeline of achievements, and contact information.

## 🌟 Features

- **Responsive Design**: Mobile-first design that works seamlessly on all devices
- **Dark Mode**: Automatic dark mode support with system preference detection
- **Fast Performance**: Optimized for speed with lazy loading and efficient caching
- **SEO Optimized**: Structured data, meta tags, and Open Graph for better search visibility
- **Accessibility**: WCAG 2.1 compliant with semantic HTML and ARIA labels
- **Content Sections**:
  - **About**: Professional profile with skills, interests, and research focus
  - **Timeline**: Chronological milestones in education, career, and achievements
  - **Publications**: Academic papers and research publications
  - **Reading List**: Books and resources with reviews
  - **Contact**: Encrypted contact form with PGP support

## 🚀 Quick Start

### Prerequisites

- **Hugo Extended** v0.152.0 or higher
- **Node.js** v25.0.0 or higher
- **npm** (comes with Node.js)

### Installation

1. **Clone the repository**:

   ```bash
   git clone https://github.com/lbenicio/blog.git
   cd blog
   ```

2. **Install dependencies**:

   ```bash
   npm install
   ```

3. **Initialize Hugo modules** (first time only):

   ```bash
   hugo mod init github.com/lbenicio/blog
   hugo mod get github.com/lbenicio/aboutme-v2-theme
   ```

4. **Start the development server**:

   ```bash
   hugo server
   ```

5. **Open your browser**:
   Navigate to `http://localhost:1313`

## 📁 Project Structure

```text
blog/
├── content/              # Site content
│   ├── about/           # About section with certifications
│   ├── contact/         # Contact page
│   ├── publications/    # Research publications
│   ├── reading/         # Reading list and book reviews
│   └── timeline/        # Timeline of achievements
├── static/              # Static assets (images, fonts)
├── hugo.toml           # Site configuration
├── package.json        # Node.js dependencies
└── theme/              # Theme (as git submodule or linked)
```

## ⚙️ Configuration

### Site Configuration (`hugo.toml`)

The site is configured for "ABOUT_ONLY" mode, focusing on personal branding rather than blogging. Key configuration options:

```toml
[params]
  # Site Mode
  appMode = "ABOUT_ONLY"
  siteUrl = "https://lbenicio.dev"
  
  # Profile
  homepageHeading = "About Leonardo Benicio"
  homepageSubtitle = "Personal tagline or description"
  
  # Contact
  contactEmail = "your@email.com"
  contactPostUrl = "https://formbold.com/s/your-form-id"
  
  # Social Media
  githubHandler = "yourusername"
  linkedinHandler = "your-profile"
  twitterHandler = "yourusername"
  
  # Skills & Interests
  skills = ["Skill 1", "Skill 2", "Skill 3"]
  interests = ["Interest 1", "Interest 2"]
  researchInterests = ["Research Interest 1", "Research Interest 2"]
```

### Content Structure

#### Timeline (`content/timeline/_index.md`)

The timeline uses frontmatter to store milestone data:

```yaml
---
Title: "Timeline"
description: "A chronological timeline of milestones"
timeline:
  - date: 2024-06
    title: "Your Milestone"
    category: career
    description: "Description of the milestone"
    links:
      - label: "Related Link"
        href: "/related-page/"
    highlight: true
---
```

#### About Page (`content/about/_index.md`)

The about page includes certifications in frontmatter:

```yaml
---
Title: "About Me"
description: "About page description"
certifications:
  - id: aws-cloud-practitioner
    name: AWS Certified Cloud Practitioner
    issuer: Amazon Web Services
    level: Foundational
    issued: 2024-06
    domainTags:
      - cloud
      - aws
    skills:
      - Cloud Concepts
      - Security
    url: https://aws.amazon.com/certification/
    notes: "Additional notes"
---
```

## 🎨 Customization

### Adding Your Content

1. **Update Personal Information**:
   - Edit `hugo.toml` to change name, email, social links
   - Update profile pictures in `static/assets/images/avatar/`

2. **Modify Timeline**:
   - Edit `content/timeline/_index.md`
   - Add new milestones with proper dates and categories

3. **Add Publications**:
   - Create new files in `content/publications/`
   - Follow the existing template format

4. **Update Reading List**:
   - Add entries in `content/reading/`
   - Include reviews and ratings

5. **Customize Skills**:
   - Update the `skills` array in `hugo.toml`
   - Add relevant technical and professional skills

### Styling

The site uses the aboutme-v2-theme for styling. To customize:

1. **Theme Configuration**: Modify `theme.toml` in the theme directory
2. **Custom CSS**: Add custom styles in `static/custom.css`
3. **Override Templates**: Create template overrides in `layouts/`

## 📦 Dependencies

### Node.js Dependencies

```json
{
  "dependencies": {
    "@tailwindcss/postcss": "^4",
    "@tailwindcss/typography": "^0.5.19",
    "tailwindcss": "^4.3.0",
    "tailwindcss-animate": "^1.0.7",
    "postcss": "^8.5.15",
    "autoprefixer": "^10.5.0"
  },
  "devDependencies": {
    "postcss-cli": "^11.0.1"
  }
}
```

These are required for Tailwind CSS processing during development and production builds.

## 🧪 Testing

The theme includes comprehensive tests. To run tests:

```bash
# From the theme directory
cd ../aboutme-v2-theme
npm run test:e2e
```

## 🚢 Deployment

### Building for Production

```bash
# Build the site
hugo --minify --environment production

# Output will be in the `public/` directory
```

### Deployment Options

#### Static Hosting

Deploy the `public/` directory to any static hosting service:

- **Netlify**: Connect your Git repository
- **Vercel**: Import your project
- **GitHub Pages**: Use GitHub Actions
- **Cloudflare Pages**: Connect your repository

#### Manual Deployment

```bash
# Build
hugo --minify

# Deploy to server
rsync -avz public/ user@server:/var/www/html/
```

### Environment Variables

The site uses environment-specific configuration:

```bash
# Development
HUGO_ENV=development hugo server

# Production
HUGO_ENV=production hugo --minify
```

## 🔧 Development Workflow

### Adding New Content

1. **Create new content file**:
   ```bash
   hugo new publications/my-paper.md
   ```

2. **Edit the file** with your content and frontmatter

3. **Preview changes**:
   ```bash
   hugo server --themesDir ../../
   ```

### Updating Dependencies

```bash
# Update theme
cd ../aboutme-v2-theme
npm run deps:update

# Update site dependencies
cd ../blog
npm update
```

### Monitoring and Analytics

The site integrates with Umami for analytics:

```toml
[params]
  umamiWebsiteId = "your-website-id"
  umamiScriptUrl = "https://your-analytics-url/script.js"
```

## 🔒 Security

### Contact Form Security

- Uses Formbold for spam protection
- Supports PGP encryption for sensitive communications
- No server-side processing required

### Content Security

- Hugo's built-in security features enabled
- No external script dependencies (except analytics)
- Static site architecture reduces attack surface

## 📊 Performance Optimization

### Built-in Optimizations

- **Image Optimization**: AVIF/WebP formats with fallbacks
- **CSS Minification**: Automatic in production builds
- **JavaScript Minification**: Theme handles obfuscation
- **Lazy Loading**: Images and content loaded on demand
- **Caching**: Proper cache headers configured

### Performance Monitoring

Monitor site performance using:

- Google PageSpeed Insights
- Lighthouse CI
- Web Vitals tracking

## 🤝 Contributing

While this is a personal site, suggestions and improvements are welcome:

1. Fork the repository
2. Create your feature branch
3. Make your changes
4. Submit a pull request

## 📝 License

This site is licensed under the GPL-3.0 license - see the [LICENSE](LICENSE.txt) file for details.

## 🙏 Acknowledgments

- [aboutme-v2-theme](https://github.com/lbenicio/aboutme-v2-theme) - Theme framework
- [Hugo](https://gohugo.io/) - Static site generator
- [Tailwind CSS](https://tailwindcss.com/) - Styling framework
- [Formbold](https://formbold.com/) - Contact form service
- [Umami](https://umami.is/) - Analytics service

## 📧 Contact

- **Email**: hi@lbenicio.dev
- **GitHub**: [@lbenicio](https://github.com/lbenicio)
- **LinkedIn**: [leonardo-benicio](https://www.linkedin.com/in/leonardo-benicio)
- **Twitter**: [@lbenicio_](https://twitter.com/lbenicio_)

## 🔗 Related Resources

- [Theme Documentation](https://github.com/lbenicio/aboutme-v2-theme)
- [Hugo Documentation](https://gohugo.io/documentation/)
- [Tailwind CSS Guide](https://tailwindcss.com/docs)
- [Live Site](https://lbenicio.dev)

---

**Built with Hugo and aboutme-v2-theme • © 2024 Leonardo Benicio**
